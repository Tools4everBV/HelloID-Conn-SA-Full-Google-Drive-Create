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

function Get-GoogleWSAccessToken {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Issuer,

        [Parameter()]
        [string]
        $Subject,

        [Parameter()]
        [string[]]$Scopes,

        [Parameter()]
        [string]
        $P12CertificateBase64,

        [Parameter()]
        [string]
        $P12CertificatePassword
    )

    try {
        $now = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]"1970-01-01T00:00:00Z").ToUniversalTime()).TotalSeconds)
        $jwtHeader = @{
            alg = 'RS256'
            typ = 'JWT'
        } | ConvertTo-Json
        $jwtBase64Header = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jwtHeader))

        $jwtPayload = [Ordered]@{
            iss   = $Issuer
            sub   = $Subject
            scope = $($Scopes -join " ")
            aud   = "https://www.googleapis.com/oauth2/v4/token"
            exp   = $now + 3600
            iat   = $now
        } | ConvertTo-Json
        $jwtBase64Payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jwtPayload))

        $rawP12Certificate = [system.convert]::FromBase64String($P12CertificateBase64)
        $p12Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rawP12Certificate, $P12CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        $rsaPrivate = $P12Certificate.PrivateKey
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        $rsa.ImportParameters($rsaPrivate.ExportParameters($true))
        $signatureInput = "$jwtBase64Header.$jwtBase64Payload"
        $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signatureInput), "SHA256")
        $base64Signature = [System.Convert]::ToBase64String($signature)
        $jwtToken = "$signatureInput.$base64Signature"

        $splatParams = @{
            Uri         = 'https://www.googleapis.com/oauth2/v4/token'
            Method      = 'POST'
            Body        = @{
                grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
                assertion  = $jwtToken
            }
            ContentType = 'application/x-www-form-urlencoded'
        }
        $response = Invoke-RestMethod @splatParams
        $response.access_token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

#endregion functions

try {
    #region Create access token
    $actionMessage = "creating acess token"

    Write-Information 'Getting JWT token'
    $splatGetGoogleWSTokenParams = @{
        Issuer                 = "$($serviceAccountEmail)"
        Subject                = "$($userId)"
        Scopes                 = "$($scopes -join " ")"
        P12CertificateBase64   = $p12CertificateBase64
        P12CertificatePassword = $p12CertificatePassword
    }

    $createAccessTokenResponse = Get-GoogleWSAccessToken @splatGetGoogleWSTokenParams

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
