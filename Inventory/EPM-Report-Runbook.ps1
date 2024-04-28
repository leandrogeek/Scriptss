# Set some variables
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$CosmosDBEndPoint = "<INSERT Cosmos DB URL HERE>"
$DatabaseId = "InventoryDatabase"
$MasterKey = "<INSERT Cosmos DB write Primary Key HERE>"


# add necessary assembly
#
Add-Type -AssemblyName System.Web

####################################################
# Connect to Azure
$resourceURL = "https://graph.microsoft.com/" 
$response = [System.Text.Encoding]::Default.GetString((Invoke-WebRequest -UseBasicParsing -Uri "$($env:IDENTITY_ENDPOINT)?resource=$resourceURL" -Method 'GET' -Headers @{'X-IDENTITY-HEADER' = "$env:IDENTITY_HEADER"; 'Metadata' = 'True'}).RawContentStream.ToArray()) | ConvertFrom-Json 
#$script:authToken = $response.access_token 

$script:authToken = @{
    'Content-Type'  = 'application/json'
    'Authorization' = "Bearer " + $response.access_token
}

######################################################

# generate authorization key
Function Generate-MasterKeyAuthorizationSignature
{
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory=$true)][String]$verb,
		[Parameter(Mandatory=$true)][String]$resourceLink,
		[Parameter(Mandatory=$true)][String]$resourceType,
		[Parameter(Mandatory=$true)][String]$dateTime,
		[Parameter(Mandatory=$true)][String]$key,
		[Parameter(Mandatory=$true)][String]$keyType,
		[Parameter(Mandatory=$true)][String]$tokenVersion
	)

	$hmacSha256 = New-Object System.Security.Cryptography.HMACSHA256
	$hmacSha256.Key = [System.Convert]::FromBase64String($key)

	$payLoad = "$($verb.ToLowerInvariant())`n$($resourceType.ToLowerInvariant())`n$resourceLink`n$($dateTime.ToLowerInvariant())`n`n"
	$hashPayLoad = $hmacSha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payLoad))
	$signature = [System.Convert]::ToBase64String($hashPayLoad);

	[System.Web.HttpUtility]::UrlEncode("type=$keyType&ver=$tokenVersion&sig=$signature")
}

# query
Function Post-CosmosDb
{
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory=$true)][String]$EndPoint,
		[Parameter(Mandatory=$true)][String]$DataBaseId,
		[Parameter(Mandatory=$true)][String]$CollectionId,
		[Parameter(Mandatory=$true)][String]$MasterKey,
		[Parameter(Mandatory=$true)][String]$JSON
	)
try {
	$Verb = "POST"
	$ResourceType = "docs";
	$ResourceLink = "dbs/$DatabaseId/colls/$CollectionId"
    $partitionkey = "[""$(($JSON |ConvertFrom-Json).id)""]"

	$dateTime = [DateTime]::UtcNow.ToString("r")
	$authHeader = Generate-MasterKeyAuthorizationSignature -verb $Verb -resourceLink $ResourceLink -resourceType $ResourceType -key $MasterKey -keyType "master" -tokenVersion "1.0" -dateTime $dateTime
	$header = @{authorization=$authHeader;"x-ms-documentdb-partitionkey"=$partitionkey;"x-ms-version"="2018-12-31";"x-ms-date"=$dateTime}
	$contentType= "application/json"
	$queryUri = "$EndPoint$ResourceLink/docs"

	#Convert to UTF8 for special characters
	$defaultEncoding = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
	$utf8Bytes = [System.Text.Encoding]::UTf8.GetBytes($JSON)
	$bodydecoded = $defaultEncoding.GetString($utf8bytes)

	Invoke-RestMethod -Method $Verb -ContentType $contentType -Uri $queryUri -Headers $header -Body $bodydecoded -ErrorAction SilentlyContinue
   } 
   catch 
   {
    return $_.Exception.Response.StatusCode.value__ 
   }
    
	
}

Function Replace-CosmosDb
{
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory=$true)][String]$EndPoint,
		[Parameter(Mandatory=$true)][String]$DataBaseId,
		[Parameter(Mandatory=$true)][String]$CollectionId,
		[Parameter(Mandatory=$true)][String]$MasterKey,
		[Parameter(Mandatory=$true)][String]$JSON
	)
try {
	$Verb = "PUT"
	$ResourceType = "docs";
    $partitionkey = "[""$(($JSON |ConvertFrom-Json).id)""]"
    $DocID=($JSON |ConvertFrom-Json).id
	$ResourceLink = "dbs/$DatabaseId/colls/$CollectionId/docs/$DocID"


	$dateTime = [DateTime]::UtcNow.ToString("r")
	$authHeader = Generate-MasterKeyAuthorizationSignature -verb $Verb -resourceLink $ResourceLink -resourceType $ResourceType -key $MasterKey -keyType "master" -tokenVersion "1.0" -dateTime $dateTime
	$header = @{authorization=$authHeader;"x-ms-documentdb-partitionkey"=$partitionkey;"x-ms-version"="2018-12-31";"x-ms-date"=$dateTime}
	$contentType= "application/json"
	$queryUri = "$EndPoint$ResourceLink/"

	#Convert to UTF8 for special characters
	$defaultEncoding = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
	$utf8Bytes = [System.Text.Encoding]::UTf8.GetBytes($JSON)
	$bodydecoded = $defaultEncoding.GetString($utf8bytes)

	Invoke-RestMethod -Method $Verb -ContentType $contentType -Uri $queryUri -Headers $header -Body $bodydecoded -ErrorAction SilentlyContinue
    } 
   catch 
   {
    return $_.Exception.Response.StatusCode.value__ 
   }
    
	
}

Function SendIntuneData-CosmosDb
{
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory=$true)][String]$EndPoint,
		[Parameter(Mandatory=$true)][String]$DataBaseId,
		[Parameter(Mandatory=$true)][String]$CollectionId,
		[Parameter(Mandatory=$true)][String]$MasterKey,
		[Parameter(Mandatory=$true)][String]$JSON
	)

    
    $DeviceResult=Replace-CosmosDb -EndPoint $EndPoint -DataBaseId $DataBaseId -CollectionId $CollectionId -MasterKey $MasterKey -JSON $JSON
        If ($DeviceResult -eq "404")
            {
            $DeviceResult=Post-CosmosDb -EndPoint $EndPoint -DataBaseId $DataBaseId -CollectionId $CollectionId -MasterKey $MasterKey -JSON $JSON
            If ($DeviceResult -eq "429")
                {
                    Start-Sleep 1
                    $DeviceResult=Post-CosmosDb -EndPoint $EndPoint -DataBaseId $DataBaseId -CollectionId $CollectionId -MasterKey $MasterKey -JSON $JSON
                }
            }
        elseif ($DeviceResult -eq "429")
            {
                Start-Sleep 1
                $DeviceResult=Replace-CosmosDb -EndPoint $EndPoint -DataBaseId $DataBaseId -CollectionId $CollectionId -MasterKey $MasterKey -JSON $JSON
            }
}
####################################################EPM Report####################################################
Write-Output "Export EPM Report"
$URI = "https://graph.microsoft.com/beta/deviceManagement/privilegeManagementElevations"
$Response = Invoke-WebRequest -Uri $URI -Method Get -Headers $authToken -UseBasicParsing 
$JsonResponse = $Response.Content | ConvertFrom-Json
$EPMData = $JsonResponse.value
If ($JsonResponse.'@odata.nextLink')
{
    do {
        $URI = $JsonResponse.'@odata.nextLink'
        $Response = Invoke-WebRequest -Uri $URI -Method Get -Headers $authToken -UseBasicParsing 
        $JsonResponse = $Response.Content | ConvertFrom-Json
        $EPMData += $JsonResponse.value
    } until ($null -eq $JsonResponse.'@odata.nextLink')
}


foreach ($EPM in $EPMData)
{
$EPM = $EPM | ConvertTo-Json
$DeviceResult=SendIntuneData-CosmosDb -EndPoint $CosmosDBEndPoint -DataBaseId $DataBaseId -CollectionId "IntuneEPMContainer" -MasterKey $MasterKey -JSON $EPM
} 

$EPMData =""

[system.gc]::Collect()
