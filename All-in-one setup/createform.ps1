# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

#HelloID variables
#Note: when running this script inside HelloID; portalUrl and API credentials are provided automatically (generate and save API credentials first in your admin panel!)
$portalUrl = "https://CUSTOMER.helloid.com"
$apiKey = "API_KEY"
$apiSecret = "API_SECRET"
$delegatedFormAccessGroupNames = @("") #Only unique names are supported. Groups must exist!
$delegatedFormCategories = @("Google") #Only unique names are supported. Categories will be created if not exists
$script:debugLogging = $false #Default value: $false. If $true, the HelloID resource GUIDs will be shown in the logging
$script:duplicateForm = $false #Default value: $false. If $true, the HelloID resource names will be changed to import a duplicate Form
$script:duplicateFormSuffix = "_tmp" #the suffix will be added to all HelloID resource names to generate a duplicate form with different resource names

#The following HelloID Global variables are used by this form. No existing HelloID global variables will be overriden only new ones are created.
#NOTE: You can also update the HelloID Global variable values afterwards in the HelloID Admin Portal: https://<CUSTOMER>.helloid.com/admin/variablelibrary
$globalHelloIDVariables = [System.Collections.Generic.List[object]]@();

#Global variable #1 >> GoogleP12CertificateBase64
$tmpName = @'
GoogleP12CertificateBase64
'@ 
$tmpValue = ""
$globalHelloIDVariables.Add([PSCustomObject]@{name = $tmpName; value = $tmpValue; secret = "False"});

#Global variable #2 >> GoogleServiceAccountEmail
$tmpName = @'
GoogleServiceAccountEmail
'@ 
$tmpValue = ""
$globalHelloIDVariables.Add([PSCustomObject]@{name = $tmpName; value = $tmpValue; secret = "False"});

#Global variable #3 >> GoogleP12CertificatePassword
$tmpName = @'
GoogleP12CertificatePassword
'@ 
$tmpValue = "" 
$globalHelloIDVariables.Add([PSCustomObject]@{name = $tmpName; value = $tmpValue; secret = "True"});

#Global variable #4 >> GoogleAdminEmail
$tmpName = @'
GoogleAdminEmail
'@ 
$tmpValue = ""
$globalHelloIDVariables.Add([PSCustomObject]@{name = $tmpName; value = $tmpValue; secret = "False"});

#Global variable #5 >> GoogleUsersOrgUnitPath
$tmpName = @'
GoogleUsersOrgUnitPath
'@ 
$tmpValue = @'
/Users
'@ 
$globalHelloIDVariables.Add([PSCustomObject]@{name = $tmpName; value = $tmpValue; secret = "False"});


#make sure write-information logging is visual
$InformationPreference = "continue"

# Check for prefilled API Authorization header
if (-not [string]::IsNullOrEmpty($portalApiBasic)) {
    $script:headers = @{"authorization" = $portalApiBasic}
    Write-Information "Using prefilled API credentials"
} else {
    # Create authorization headers with HelloID API key
    $pair = "$apiKey" + ":" + "$apiSecret"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $key = "Basic $base64"
    $script:headers = @{"authorization" = $Key}
    Write-Information "Using manual API credentials"
}

# Check for prefilled PortalBaseURL
if (-not [string]::IsNullOrEmpty($portalBaseUrl)) {
    $script:PortalBaseUrl = $portalBaseUrl
    Write-Information "Using prefilled PortalURL: $script:PortalBaseUrl"
} else {
    $script:PortalBaseUrl = $portalUrl
    Write-Information "Using manual PortalURL: $script:PortalBaseUrl"
}

# Define specific endpoint URI
$script:PortalBaseUrl = $script:PortalBaseUrl.trim("/") + "/"  

# Make sure to reveive an empty array using PowerShell Core
function ConvertFrom-Json-WithEmptyArray([string]$jsonString) {
    # Running in PowerShell Core?
    if($IsCoreCLR -eq $true){
        $r = [Object[]]($jsonString | ConvertFrom-Json -NoEnumerate)
        return ,$r  # Force return value to be an array using a comma
    } else {
        $r = [Object[]]($jsonString | ConvertFrom-Json)
        return ,$r  # Force return value to be an array using a comma
    }
}

function Invoke-HelloIDGlobalVariable {
    param(
        [parameter(Mandatory)][String]$Name,
        [parameter(Mandatory)][String][AllowEmptyString()]$Value,
        [parameter(Mandatory)][String]$Secret
    )

    $Name = $Name + $(if ($script:duplicateForm -eq $true) { $script:duplicateFormSuffix })

    try {
        $uri = ($script:PortalBaseUrl + "api/v1/automation/variables/named/$Name")
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
    
        if ([string]::IsNullOrEmpty($response.automationVariableGuid)) {
            #Create Variable
            $body = @{
                name     = $Name;
                value    = $Value;
                secret   = $Secret;
                ItemType = 0;
            }    
            $body = ConvertTo-Json -InputObject $body -Depth 100
    
            $uri = ($script:PortalBaseUrl + "api/v1/automation/variable")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
            $variableGuid = $response.automationVariableGuid

            Write-Information "Variable '$Name' created$(if ($script:debugLogging -eq $true) { ": " + $variableGuid })"
        } else {
            $variableGuid = $response.automationVariableGuid
            Write-Warning "Variable '$Name' already exists$(if ($script:debugLogging -eq $true) { ": " + $variableGuid })"
        }
    } catch {
        Write-Error "Variable '$Name', message: $_"
    }
}

function Invoke-HelloIDAutomationTask {
    param(
        [parameter(Mandatory)][String]$TaskName,
        [parameter(Mandatory)][String]$UseTemplate,
        [parameter(Mandatory)][String]$AutomationContainer,
        [parameter(Mandatory)][String][AllowEmptyString()]$Variables,
        [parameter(Mandatory)][String]$PowershellScript,
        [parameter()][String][AllowEmptyString()]$ObjectGuid,
        [parameter()][String][AllowEmptyString()]$ForceCreateTask,
        [parameter(Mandatory)][Ref]$returnObject
    )
    
    $TaskName = $TaskName + $(if ($script:duplicateForm -eq $true) { $script:duplicateFormSuffix })

    try {
        $uri = ($script:PortalBaseUrl +"api/v1/automationtasks?search=$TaskName&container=$AutomationContainer")
        $responseRaw = (Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false) 
        $response = $responseRaw | Where-Object -filter {$_.name -eq $TaskName}
    
        if([string]::IsNullOrEmpty($response.automationTaskGuid) -or $ForceCreateTask -eq $true) {
            #Create Task

            $body = @{
                name                = $TaskName;
                useTemplate         = $UseTemplate;
                powerShellScript    = $PowershellScript;
                automationContainer = $AutomationContainer;
                objectGuid          = $ObjectGuid;
                variables           = (ConvertFrom-Json-WithEmptyArray($Variables));
            }
            $body = ConvertTo-Json -InputObject $body -Depth 100
    
            $uri = ($script:PortalBaseUrl +"api/v1/automationtasks/powershell")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
            $taskGuid = $response.automationTaskGuid

            Write-Information "Powershell task '$TaskName' created$(if ($script:debugLogging -eq $true) { ": " + $taskGuid })"
        } else {
            #Get TaskGUID
            $taskGuid = $response.automationTaskGuid
            Write-Warning "Powershell task '$TaskName' already exists$(if ($script:debugLogging -eq $true) { ": " + $taskGuid })"
        }
    } catch {
        Write-Error "Powershell task '$TaskName', message: $_"
    }

    $returnObject.Value = $taskGuid
}

function Invoke-HelloIDDatasource {
    param(
        [parameter(Mandatory)][String]$DatasourceName,
        [parameter(Mandatory)][String]$DatasourceType,
        [parameter(Mandatory)][String][AllowEmptyString()]$DatasourceModel,
        [parameter()][String][AllowEmptyString()]$DatasourceStaticValue,
        [parameter()][String][AllowEmptyString()]$DatasourcePsScript,        
        [parameter()][String][AllowEmptyString()]$DatasourceInput,
        [parameter()][String][AllowEmptyString()]$AutomationTaskGuid,
        [parameter()][String][AllowEmptyString()]$DatasourceRunInCloud,
        [parameter(Mandatory)][Ref]$returnObject
    )

    $DatasourceName = $DatasourceName + $(if ($script:duplicateForm -eq $true) { $script:duplicateFormSuffix })

    $datasourceTypeName = switch($DatasourceType) { 
        "1" { "Native data source"; break} 
        "2" { "Static data source"; break} 
        "3" { "Task data source"; break} 
        "4" { "Powershell data source"; break}
    }
    
    try {
        $uri = ($script:PortalBaseUrl +"api/v1/datasource/named/$DatasourceName")
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
      
        if([string]::IsNullOrEmpty($response.dataSourceGUID)) {
            #Create DataSource
            $body = @{
                name               = $DatasourceName;
                type               = $DatasourceType;
                model              = (ConvertFrom-Json-WithEmptyArray($DatasourceModel));
                automationTaskGUID = $AutomationTaskGuid;
                value              = (ConvertFrom-Json-WithEmptyArray($DatasourceStaticValue));
                script             = $DatasourcePsScript;
                input              = (ConvertFrom-Json-WithEmptyArray($DatasourceInput));
                runInCloud         = $DatasourceRunInCloud;
            }
            $body = ConvertTo-Json -InputObject $body -Depth 100
      
            $uri = ($script:PortalBaseUrl +"api/v1/datasource")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
              
            $datasourceGuid = $response.dataSourceGUID
            Write-Information "$datasourceTypeName '$DatasourceName' created$(if ($script:debugLogging -eq $true) { ": " + $datasourceGuid })"
        } else {
            #Get DatasourceGUID
            $datasourceGuid = $response.dataSourceGUID
            Write-Warning "$datasourceTypeName '$DatasourceName' already exists$(if ($script:debugLogging -eq $true) { ": " + $datasourceGuid })"
        }
    } catch {
      Write-Error "$datasourceTypeName '$DatasourceName', message: $_"
    }

    $returnObject.Value = $datasourceGuid
}

function Invoke-HelloIDDynamicForm {
    param(
        [parameter(Mandatory)][String]$FormName,
        [parameter(Mandatory)][String]$FormSchema,
        [parameter(Mandatory)][Ref]$returnObject
    )
    
    $FormName = $FormName + $(if ($script:duplicateForm -eq $true) { $script:duplicateFormSuffix })

    try {
        try {
            $uri = ($script:PortalBaseUrl +"api/v1/forms/$FormName")
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
        } catch {
            $response = $null
        }
    
        if(([string]::IsNullOrEmpty($response.dynamicFormGUID)) -or ($response.isUpdated -eq $true)) {
            #Create Dynamic form
            $body = @{
                Name       = $FormName;
                FormSchema = (ConvertFrom-Json-WithEmptyArray($FormSchema));
            }
            $body = ConvertTo-Json -InputObject $body -Depth 100
    
            $uri = ($script:PortalBaseUrl +"api/v1/forms")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
    
            $formGuid = $response.dynamicFormGUID
            Write-Information "Dynamic form '$formName' created$(if ($script:debugLogging -eq $true) { ": " + $formGuid })"
        } else {
            $formGuid = $response.dynamicFormGUID
            Write-Warning "Dynamic form '$FormName' already exists$(if ($script:debugLogging -eq $true) { ": " + $formGuid })"
        }
    } catch {
        Write-Error "Dynamic form '$FormName', message: $_"
    }

    $returnObject.Value = $formGuid
}


function Invoke-HelloIDDelegatedForm {
    param(
        [parameter(Mandatory)][String]$DelegatedFormName,
        [parameter(Mandatory)][String]$DynamicFormGuid,
        [parameter()][Array][AllowEmptyString()]$AccessGroups,
        [parameter()][String][AllowEmptyString()]$Categories,
        [parameter(Mandatory)][String]$UseFaIcon,
        [parameter()][String][AllowEmptyString()]$FaIcon,
        [parameter()][String][AllowEmptyString()]$task,
        [parameter(Mandatory)][Ref]$returnObject
    )
    $delegatedFormCreated = $false
    $DelegatedFormName = $DelegatedFormName + $(if ($script:duplicateForm -eq $true) { $script:duplicateFormSuffix })

    try {
        try {
            $uri = ($script:PortalBaseUrl +"api/v1/delegatedforms/$DelegatedFormName")
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
        } catch {
            $response = $null
        }
    
        if([string]::IsNullOrEmpty($response.delegatedFormGUID)) {
            #Create DelegatedForm
            $body = @{
                name            = $DelegatedFormName;
                dynamicFormGUID = $DynamicFormGuid;
                isEnabled       = "True";
                useFaIcon       = $UseFaIcon;
                faIcon          = $FaIcon;
                task            = ConvertFrom-Json -inputObject $task;
            }
            if(-not[String]::IsNullOrEmpty($AccessGroups)) { 
                $body += @{
                    accessGroups    = (ConvertFrom-Json-WithEmptyArray($AccessGroups));
                }
            }
            $body = ConvertTo-Json -InputObject $body -Depth 100
    
            $uri = ($script:PortalBaseUrl +"api/v1/delegatedforms")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
    
            $delegatedFormGuid = $response.delegatedFormGUID
            Write-Information "Delegated form '$DelegatedFormName' created$(if ($script:debugLogging -eq $true) { ": " + $delegatedFormGuid })"
            $delegatedFormCreated = $true

            $bodyCategories = $Categories
            $uri = ($script:PortalBaseUrl +"api/v1/delegatedforms/$delegatedFormGuid/categories")
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $bodyCategories
            Write-Information "Delegated form '$DelegatedFormName' updated with categories"
        } else {
            #Get delegatedFormGUID
            $delegatedFormGuid = $response.delegatedFormGUID
            Write-Warning "Delegated form '$DelegatedFormName' already exists$(if ($script:debugLogging -eq $true) { ": " + $delegatedFormGuid })"
        }
    } catch {
        Write-Error "Delegated form '$DelegatedFormName', message: $_"
    }

    $returnObject.value.guid = $delegatedFormGuid
    $returnObject.value.created = $delegatedFormCreated
}


<# Begin: HelloID Global Variables #>
foreach ($item in $globalHelloIDVariables) {
	Invoke-HelloIDGlobalVariable -Name $item.name -Value $item.value -Secret $item.secret 
}
<# End: HelloID Global Variables #>


<# Begin: HelloID Data sources #>
<# Begin: DataSource "Google Teamdrive - Create Google-Get-User" #>
$tmpPsScript = @'
# Variables configured in form
$searchValue = $datasource.searchValue

# Fixed values
$scopes = @(
    "https://www.googleapis.com/auth/admin.directory.user"
)

# Global variables
$p12CertificateBase64 = $GoogleP12CertificateBase64
$p12CertificatePassword = $GoogleP12CertificatePassword
$serviceAccountEmail = $GoogleServiceAccountEmail
$userId = $GoogleAdminEmail # Email address of admin with permissions to manage users.
$orgUnitPath = $GoogleUsersOrgUnitPath # organizational unit of users

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
$VerbosePreference = "SilentlyContinue"
$InformationPreference = "Continue"
$WarningPreference = "Continue"

#region functions
function Resolve-GoogleError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }

        try {
            $errorObjectConverted = $ErrorObject | ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $errorObjectConverted.error_description) {
                $httpErrorObj.FriendlyMessage = $errorObjectConverted.error_description
            }
            elseif ($null -ne $errorObjectConverted.error) {
                if ($null -ne $errorObjectConverted.error.message) {
                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error.message
                    if ($null -ne $errorObjectConverted.error.code) { 
                        $httpErrorObj.FriendlyMessage = $httpErrorObj.FriendlyMessage + ". Error code: $($errorObjectConverted.error.code)"
                    }
                }
                else {
                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error
                }
            }
            else {
                $httpErrorObj.FriendlyMessage = $ErrorObject
            }
        }
        catch {
            if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
                $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
            }
            else {
                $httpErrorObj.FriendlyMessage = $ErrorObject.Exception.Message
            }
        }
            
        Write-Output $httpErrorObj
    }
}
#endregion functions

try {
    #region Create access token
    $actionMessage = "creating acess token"

    # Create a JWT (JSON Web Token) header
    $header = @{
        alg = "RS256"
        typ = "JWT"
    } | ConvertTo-Json
    $base64Header = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header))

    # Calculate the Unix timestamp for 'exp' and 'iat'
    $now = [Math]::Round((Get-Date (Get-Date).ToUniversalTime() -UFormat "%s"), 0)
    $createDate = $now
    $expiryDate = $createDate + 3540 # Expires in 59 minutes

    # Create a JWT payload
    $payload = [Ordered]@{
        iss   = "$serviceAccountEmail"
        sub   = "$userId"
        scope = "$($scopes -join " ")"
        aud   = "https://www.googleapis.com/oauth2/v4/token"
        exp   = "$expiryDate"
        iat   = "$createDate"
    } | ConvertTo-Json
    $base64Payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))

    # Convert Base64 string to certificate
    $rawP12Certificate = [system.convert]::FromBase64String($p12CertificateBase64)
    $p12Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawP12Certificate, $p12CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

    # Extract the private key from the P12 certificate
    $rsaPrivate = $P12Certificate.PrivateKey
    $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
    $rsa.ImportParameters($rsaPrivate.ExportParameters($true))

    # Sign the JWT
    $signatureInput = "$base64Header.$base64Payload"
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signatureInput), "SHA256")
    $base64Signature = [System.Convert]::ToBase64String($signature)

    # Create the JWT token
    $jwtToken = "$signatureInput.$base64Signature"

    $createAccessTokenBody = [Ordered]@{
        grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"
        assertion  = $jwtToken
    }

    $createAccessTokenSplatParams = @{
        Uri         = "https://www.googleapis.com/oauth2/v4/token"
        Method      = "POST"
        Body        = $createAccessTokenBody
        ContentType = "application/x-www-form-urlencoded"
        Verbose     = $false
        ErrorAction = "Stop"
    }

    $createAccessTokenResponse = Invoke-RestMethod @createAccessTokenSplatParams

    Write-Verbose "Created access token. Result: $($createAccessTokenResponse | ConvertTo-Json)."
    #endregion Create access token

    #region Create headers
    $actionMessage = "creating headers"

    $headers = @{
        "Authorization" = "Bearer $($createAccessTokenResponse.access_token)"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json;charset=utf-8"
    }

    Write-Verbose "Created headers. Result: $($headers | ConvertTo-Json)."
    #endregion Create headers

    #region Get Google Users
    # Google docs: https://developers.google.com/admin-sdk/directory/reference/rest/v1/users/list
    $actionMessage = "querying Google Users"

    $googleUsers = [System.Collections.ArrayList]@()

    $getGoogleUsersSplatParams = @{
        customer = "my_customer"
        query    = "email=$searchValue orgUnitPath='$orgUnitPath'"
    }

    do {
        $getGoogleUsersSplatParams = @{
            Uri         = "https://www.googleapis.com/admin/directory/v1/users"
            Headers     = $headers
            Body        = $getGoogleUsersSplatParams
            Method      = "GET"
            Verbose     = $false
            ErrorAction = "Stop"
        }
        if (-not[string]::IsNullOrEmpty($getGoogleUsersResponse.nextPageToken)) {
            $getGoogleUsersSplatParams['pageToken'] = $getGoogleUsersResponse.nextPageToken
        }

        $getGoogleUsersResponse = $null
        $getGoogleUsersResponse = Invoke-RestMethod @getGoogleUsersSplatParams
    
        if ($getGoogleUsersResponse.users -is [array]) {
            [void]$googleUsers.AddRange($getGoogleUsersResponse.users)
        }
        else {
            [void]$googleUsers.Add($getGoogleUsersResponse.users)
        }
    } while (-not[string]::IsNullOrEmpty($getGoogleUsersResponse.nextPageToken))

    Write-Information "Queried Google Users. Result count: $(($googleUsers | Measure-Object).Count)"
    #endregion Get Google Users

    if (($googleUsers | Measure-Object).Count -ge 1) {
        #region Send results to HelloID
        $actionMessage = "sending results to HelloID"

        $googleUsers | ForEach-Object {
            $outputObject = [PSCustomObject]@{
                id           = $_.id
                fullName     = $_.name.fullName
                primaryEmail = $_.primaryEmail
            }
            Write-Output $outputObject
        }
        #endregion Send results to HelloID
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-GoogleError -ErrorObject $ex
        $auditMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
        $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }

    Write-Warning $warningMessage

    Write-Error $auditMessage
}
'@ 
$tmpModel = @'
[{"key":"id","type":0},{"key":"fullName","type":0},{"key":"primaryEmail","type":0}]
'@ 
$tmpInput = @'
[{"description":null,"translateDescription":false,"inputFieldType":1,"key":"searchValue","type":0,"options":1}]
'@ 
$dataSourceGuid_0 = [PSCustomObject]@{} 
$dataSourceGuid_0_Name = @'
Google Teamdrive - Create Google-Get-User
'@ 
Invoke-HelloIDDatasource -DatasourceName $dataSourceGuid_0_Name -DatasourceType "4" -DatasourceInput $tmpInput -DatasourcePsScript $tmpPsScript -DatasourceModel $tmpModel -DataSourceRunInCloud "False" -returnObject ([Ref]$dataSourceGuid_0) 
<# End: DataSource "Google Teamdrive - Create Google-Get-User" #>
<# End: HelloID Data sources #>

<# Begin: Dynamic Form "Google Teamdrive - Create" #>
$tmpSchema = @"
[{"key":"formRow1","templateOptions":{},"fieldGroup":[{"key":"teamdrivename","templateOptions":{"label":"Teamdrive Name"},"type":"input","summaryVisibility":"Show","requiresTemplateOptions":true,"requiresKey":true,"requiresDataSource":false},{"key":"searchfieldUser","templateOptions":{"label":"Search file organizer user (enter exact email address)","required":true,"placeholder":"Exact email address of user","pattern":"^[\\w-\\.]+@([\\w-]+\\.)+[\\w-]{2,4}$"},"type":"input","summaryVisibility":"Hide element","requiresTemplateOptions":true,"requiresKey":true,"requiresDataSource":false}],"type":"formrow","requiresTemplateOptions":true,"requiresKey":true,"requiresDataSource":false},{"key":"formRow","templateOptions":{},"fieldGroup":[{"key":"user","templateOptions":{"label":"Select file organizer user","required":true,"grid":{"columns":[{"headerName":"Primary Email","field":"primaryEmail"},{"headerName":"Full Name","field":"fullName"}],"height":300,"rowSelection":"single"},"dataSourceConfig":{"dataSourceGuid":"$dataSourceGuid_0","input":{"propertyInputs":[{"propertyName":"searchValue","otherFieldValue":{"otherFieldKey":"searchfieldUser"}}]}},"useDefault":true,"searchPlaceHolder":"Search this data","allowCsvDownload":false,"defaultSelectorProperty":"primaryEmail"},"hideExpression":"!model[\"searchfieldUser\"]","type":"grid","summaryVisibility":"Show","requiresTemplateOptions":true,"requiresKey":true,"requiresDataSource":true}],"type":"formrow","requiresTemplateOptions":true,"requiresKey":true,"requiresDataSource":false}]
"@ 

$dynamicFormGuid = [PSCustomObject]@{} 
$dynamicFormName = @'
Google Teamdrive - Create
'@ 
Invoke-HelloIDDynamicForm -FormName $dynamicFormName -FormSchema $tmpSchema  -returnObject ([Ref]$dynamicFormGuid) 
<# END: Dynamic Form #>

<# Begin: Delegated Form Access Groups and Categories #>
$delegatedFormAccessGroupGuids = @()
if(-not[String]::IsNullOrEmpty($delegatedFormAccessGroupNames)){
    foreach($group in $delegatedFormAccessGroupNames) {
        try {
            $uri = ($script:PortalBaseUrl +"api/v1/groups/$group")
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
            $delegatedFormAccessGroupGuid = $response.groupGuid
            $delegatedFormAccessGroupGuids += $delegatedFormAccessGroupGuid
            
            Write-Information "HelloID (access)group '$group' successfully found$(if ($script:debugLogging -eq $true) { ": " + $delegatedFormAccessGroupGuid })"
        } catch {
            Write-Error "HelloID (access)group '$group', message: $_"
        }
    }
    if($null -ne $delegatedFormAccessGroupGuids){
        $delegatedFormAccessGroupGuids = ($delegatedFormAccessGroupGuids | Select-Object -Unique | ConvertTo-Json -Depth 100 -Compress)
    }
}

$delegatedFormCategoryGuids = @()
foreach($category in $delegatedFormCategories) {
    try {
        $uri = ($script:PortalBaseUrl +"api/v1/delegatedformcategories/$category")
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false
        $response = $response | Where-Object {$_.name.en -eq $category}
        
        $tmpGuid = $response.delegatedFormCategoryGuid
        $delegatedFormCategoryGuids += $tmpGuid
        
        Write-Information "HelloID Delegated Form category '$category' successfully found$(if ($script:debugLogging -eq $true) { ": " + $tmpGuid })"
    } catch {
        Write-Warning "HelloID Delegated Form category '$category' not found"
        $body = @{
            name = @{"en" = $category};
        }
        $body = ConvertTo-Json -InputObject $body -Depth 100

        $uri = ($script:PortalBaseUrl +"api/v1/delegatedformcategories")
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $script:headers -ContentType "application/json" -Verbose:$false -Body $body
        $tmpGuid = $response.delegatedFormCategoryGuid
        $delegatedFormCategoryGuids += $tmpGuid

        Write-Information "HelloID Delegated Form category '$category' successfully created$(if ($script:debugLogging -eq $true) { ": " + $tmpGuid })"
    }
}
$delegatedFormCategoryGuids = (ConvertTo-Json -InputObject $delegatedFormCategoryGuids -Depth 100 -Compress)
<# End: Delegated Form Access Groups and Categories #>

<# Begin: Delegated Form #>
$delegatedFormRef = [PSCustomObject]@{guid = $null; created = $null} 
$delegatedFormName = @'
Google Teamdrive - Create
'@
$tmpTask = @'
{"name":"Google Teamdrive - Create","script":"# Variables configured in form\r\n$organizerEmail = $form.user.primaryEmail\r\n$organizerType = \"fileOrganizer\"\r\n$driveName = $form.teamdrivename\r\n\r\n# Fixed values\r\n$scopes = @(\r\n    \"https://www.googleapis.com/auth/admin.directory.group\"\r\n    \"https://www.googleapis.com/auth/admin.directory.user\"\r\n    \"https://www.googleapis.com/auth/drive\"\r\n)\r\n\r\n# Global variables\r\n$p12CertificateBase64 = $GoogleP12CertificateBase64\r\n$p12CertificatePassword = $GoogleP12CertificatePassword\r\n$serviceAccountEmail = $GoogleServiceAccountEmail\r\n$userId = $GoogleAdminEmail # Email address of admin with permissions to manage groups and users.\r\n\r\n# Enable TLS1.2\r\n[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12\r\n\r\n# Set debug logging\r\n$VerbosePreference = \"SilentlyContinue\"\r\n$InformationPreference = \"Continue\"\r\n$WarningPreference = \"Continue\"\r\n\r\n#region functions\r\nfunction Resolve-GoogleError {\r\n    [CmdletBinding()]\r\n    param (\r\n        [Parameter(Mandatory)]\r\n        [object]\r\n        $ErrorObject\r\n    )\r\n    process {\r\n        $httpErrorObj = [PSCustomObject]@{\r\n            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber\r\n            Line             = $ErrorObject.InvocationInfo.Line\r\n            ErrorDetails     = $ErrorObject.Exception.Message\r\n            FriendlyMessage  = $ErrorObject.Exception.Message\r\n        }\r\n        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {\r\n            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message\r\n        }\r\n        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {\r\n            if ($null -ne $ErrorObject.Exception.Response) {\r\n                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()\r\n                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {\r\n                    $httpErrorObj.ErrorDetails = $streamReaderResponse\r\n                }\r\n            }\r\n        }\r\n\r\n        try {\r\n            $errorObjectConverted = $ErrorObject | ConvertFrom-Json -ErrorAction Stop\r\n\r\n            if ($null -ne $errorObjectConverted.error_description) {\r\n                $httpErrorObj.FriendlyMessage = $errorObjectConverted.error_description\r\n            }\r\n            elseif ($null -ne $errorObjectConverted.error) {\r\n                if ($null -ne $errorObjectConverted.error.message) {\r\n                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error.message\r\n                    if ($null -ne $errorObjectConverted.error.code) { \r\n                        $httpErrorObj.FriendlyMessage = $httpErrorObj.FriendlyMessage + \". Error code: $($errorObjectConverted.error.code)\"\r\n                    }\r\n                }\r\n                else {\r\n                    $httpErrorObj.FriendlyMessage = $errorObjectConverted.error\r\n                }\r\n            }\r\n            else {\r\n                $httpErrorObj.FriendlyMessage = $ErrorObject\r\n            }\r\n        }\r\n        catch {\r\n            if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {\r\n                $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message\r\n            }\r\n            else {\r\n                $httpErrorObj.FriendlyMessage = $ErrorObject.Exception.Message\r\n            }\r\n        }\r\n            \r\n        Write-Output $httpErrorObj\r\n    }\r\n}\r\n\r\nfunction Resolve-HTTPError {\r\n    [CmdletBinding()]\r\n    param (\r\n        [Parameter(Mandatory,\r\n            ValueFromPipeline\r\n        )]\r\n        [object]$ErrorObject\r\n    )\r\n    process {\r\n        $httpErrorObj = [PSCustomObject]@{\r\n            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId\r\n            MyCommand             = $ErrorObject.InvocationInfo.MyCommand\r\n            RequestUri            = $ErrorObject.TargetObject.RequestUri\r\n            ScriptStackTrace      = $ErrorObject.ScriptStackTrace\r\n            ErrorMessage          = ''\r\n        }\r\n        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.Powershell.Commands.HttpResponseException') {\r\n            $httpErrorObj.ErrorMessage = $ErrorObject.ErrorDetails.Message\r\n        }\r\n        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {\r\n            $httpErrorObj.ErrorMessage = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()\r\n        }\r\n        Write-Output $httpErrorObj\r\n    }\r\n}\r\n#endregion functions\r\n\r\ntry {\r\n    #region Create access token\r\n    $actionMessage = \"creating acess token\"\r\n\r\n    # Create a JWT (JSON Web Token) header\r\n    $header = @{\r\n        alg = \"RS256\"\r\n        typ = \"JWT\"\r\n    } | ConvertTo-Json\r\n    $base64Header = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header))\r\n\r\n    # Calculate the Unix timestamp for 'exp' and 'iat'\r\n    $now = [Math]::Round((Get-Date (Get-Date).ToUniversalTime() -UFormat \"%s\"), 0)\r\n    $createDate = $now\r\n    $expiryDate = $createDate + 3540 # Expires in 59 minutes\r\n\r\n    # Create a JWT payload\r\n    $payload = [Ordered]@{\r\n        iss   = \"$serviceAccountEmail\"\r\n        sub   = \"$userId\"\r\n        scope = \"$($scopes -join \" \")\"\r\n        aud   = \"https://www.googleapis.com/oauth2/v4/token\"\r\n        exp   = \"$expiryDate\"\r\n        iat   = \"$createDate\"\r\n    } | ConvertTo-Json\r\n    $base64Payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))\r\n\r\n    # Convert Base64 string to certificate\r\n    $rawP12Certificate = [system.convert]::FromBase64String($p12CertificateBase64)\r\n    $p12Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawP12Certificate, $p12CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)\r\n\r\n    # Extract the private key from the P12 certificate\r\n    $rsaPrivate = $P12Certificate.PrivateKey\r\n    $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()\r\n    $rsa.ImportParameters($rsaPrivate.ExportParameters($true))\r\n\r\n    # Sign the JWT\r\n    $signatureInput = \"$base64Header.$base64Payload\"\r\n    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signatureInput), \"SHA256\")\r\n    $base64Signature = [System.Convert]::ToBase64String($signature)\r\n\r\n    # Create the JWT token\r\n    $jwtToken = \"$signatureInput.$base64Signature\"\r\n\r\n    $createAccessTokenBody = [Ordered]@{\r\n        grant_type = \"urn:ietf:params:oauth:grant-type:jwt-bearer\"\r\n        assertion  = $jwtToken\r\n    }\r\n\r\n    $createAccessTokenSplatParams = @{\r\n        Uri         = \"https://www.googleapis.com/oauth2/v4/token\"\r\n        Method      = \"POST\"\r\n        Body        = $createAccessTokenBody\r\n        ContentType = \"application/x-www-form-urlencoded\"\r\n        Verbose     = $false\r\n        ErrorAction = \"Stop\"\r\n    }\r\n\r\n    $createAccessTokenResponse = Invoke-RestMethod @createAccessTokenSplatParams\r\n\r\n    Write-Verbose \"Created access token. Result: $($createAccessTokenResponse | ConvertTo-Json).\"\r\n    #endregion Create access token\r\n\r\n    #region Create headers\r\n    $actionMessage = \"creating headers\"\r\n\r\n    $headers = @{\r\n        \"Authorization\" = \"Bearer $($createAccessTokenResponse.access_token)\"\r\n        \"Accept\"        = \"application/json\"\r\n        \"Content-Type\"  = \"application/json;charset=utf-8\"\r\n    }\r\n\r\n    Write-Verbose \"Created headers. Result: $($headers | ConvertTo-Json).\"\r\n    #endregion Create headers\r\n}\r\ncatch {\r\n    $ex = $PSItem\r\n    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or\r\n        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {\r\n        $errorObj = Resolve-GoogleError -ErrorObject $ex\r\n        $auditMessage = \"Error $($actionMessage). Error: $($errorObj.FriendlyMessage)\"\r\n        $warningMessage = \"Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)\"\r\n    }\r\n    else {\r\n        $auditMessage = \"Error $($actionMessage). Error: $($ex.Exception.Message)\"\r\n        $warningMessage = \"Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)\"\r\n    }\r\n\r\n    Write-Warning $warningMessage\r\n\r\n    Write-Error $auditMessage\r\n}\r\n\r\n# create teamdrive\r\nif ($null -ne $headers) {\r\n\r\n    try {\r\n        #region create teamdrive\r\n        # drives.create requires requestId (UUID) and body with name \r\n        $requestId = [guid]::NewGuid().ToString()\r\n        $uri = \"https://www.googleapis.com/drive/v3/drives?requestId=$requestId\"\r\n        $createDrivebody = @{ name = $driveName }\r\n\r\n        $actionMessage = \"creating drive with displayname [$($driveName)] \"\r\n\r\n        $createDriveSplatParams = @{\r\n            Uri         = \"https://www.googleapis.com/drive/v3/drives?requestId=$requestId\"\r\n            Headers     = $headers\r\n            Method      = \"POST\"\r\n            Body        = ($createDrivebody | ConvertTo-Json -Depth 10)\r\n            ContentType = \"application/json; charset=utf-8\"\r\n            Verbose     = $false \r\n            ErrorAction = \"Stop\"\r\n        }\r\n\r\n        $createDrive = Invoke-RestMethod @createDriveSplatParams\r\n\r\n        # Add Organizer (permissions.create on shared drive) \r\n        # Shared drives: supportsAllDrives=true\r\n        $organizerBody = @{\r\n        type         = \"user\"\r\n        role         = $organizerType\r\n        emailAddress = $OrganizerEmail\r\n        } \r\n\r\n        $addOrganizerSplatParams = @{\r\n            Uri         = \"https://www.googleapis.com/drive/v3/files/$($createDrive.id)/permissions?supportsAllDrives=true\"\r\n            Headers     = $headers\r\n            Method      = \"POST\"\r\n            Body        = ($organizerBody | ConvertTo-Json -Depth 10)\r\n            ContentType = \"application/json; charset=utf-8\"\r\n            Verbose     = $false \r\n            ErrorAction = \"Stop\"\r\n        }\r\n\r\n        $setOrganizer = Invoke-RestMethod @addOrganizerSplatParams\r\n        \r\n        Write-Verbose \"Added organizer with displayname [$($form.user.fullName)] to teamdrive with displayname [$($createDrive.name)].\"\r\n        #endregion create teamdrive\r\n        \r\n        #region Send auditlog to HelloID\r\n        $actionMessage = \"sending auditlog to HelloID\"\r\n        \r\n        $Log = @{\r\n            Action            = \"GrantPermission\" # optional. ENUM (undefined = default) \r\n            System            = \"Google\" # optional (free format text) \r\n            Message           = \"Added organizer with displayname [$($form.user.fullName)] to teamdrive with displayname [$($createDrive.name)].\" # required (free format text) \r\n            IsError           = $false # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) \r\n            TargetDisplayName = [string]$createDrive.name # optional (free format text)\r\n            TargetIdentifier  = [string]$createDrive.id # optional (free format text)\r\n        }\r\n        Write-Information -Tags \"Audit\" -MessageData $log\r\n        #endregion Send auditlog to HelloID\r\n    }\r\n    catch {\r\n        $ex = $PSItem\r\n        if ($($ex.Exception.GetType().FullName -eq \"Microsoft.PowerShell.Commands.HttpResponseException\") -or\r\n            $($ex.Exception.GetType().FullName -eq \"System.Net.WebException\")) {\r\n            $errorObj = Resolve-GoogleError -ErrorObject $ex\r\n            $auditMessage = \"Error $($actionMessage). Error: $($errorObj.FriendlyMessage)\"\r\n            $warningMessage = \"Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)\"\r\n        }\r\n        else {\r\n            $auditMessage = \"Error $($actionMessage). Error: $($ex.Exception.Message)\"\r\n            $warningMessage = \"Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)\"\r\n        }\r\n        \r\n            #region Send auditlog to HelloID\r\n            $actionMessage = \"sending auditlog to HelloID\"\r\n        \r\n            $Log = @{\r\n                Action            = \"GrantPermission\" # optional. ENUM (undefined = default)\r\n                System            = \"Google\" # optional (free format text)\r\n                Message           = $auditMessage # required (free format text)\r\n                IsError           = $true # optional. Elastic reporting purposes only. (default = $false. $true = Executed action returned an error) \r\n                TargetDisplayName = [string]$createDrive.name # optional (free format text)\r\n                TargetIdentifier  = [string]$createDrive.id # optional (free format text)\r\n            }\r\n            Write-Information -Tags \"Audit\" -MessageData $log\r\n            #endregion Send auditlog to HelloID\r\n        \r\n            Write-Warning $warningMessage\r\n        \r\n            Write-Error $auditMessage\r\n        }\r\n    }","runInCloud":true}
'@ 

Invoke-HelloIDDelegatedForm -DelegatedFormName $delegatedFormName -DynamicFormGuid $dynamicFormGuid -AccessGroups $delegatedFormAccessGroupGuids -Categories $delegatedFormCategoryGuids -UseFaIcon "True" -FaIcon "fa fa-sitemap" -task $tmpTask -returnObject ([Ref]$delegatedFormRef) 
<# End: Delegated Form #>

