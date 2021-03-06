Import-Module WebAdministration
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Invoke-WaitForWebAppPoolToChangeState($name, $state){
	$currentState = Get-WebAppPoolState -Name $name
	Write-Host "Waiting for app pool '$name' to enter the '$state' state" -NoNewLine
	DO{
		Write-Host "." -NoNewLine
		Start-Sleep 1
		$currentState = Get-WebAppPoolState -Name $name
	}while($currentState.Value -ne $state)
	Write-Host ""
}

function Add-EnvironmentVariable($variableName, $variableValue, $config){
	$environmentVariablesNode = $config.configuration.'system.webServer'.aspNetCore.environmentVariables
	$existingEnvironmentVariable = $environmentVariablesNode.environmentVariable | Where-Object {$_.name -eq $variableName}
	if($existingEnvironmentVariable -eq $null){
		Write-Console "Writing $variableName to config"
		$environmentVariable = $config.CreateElement("environmentVariable")
		
		$nameAttribute = $config.CreateAttribute("name")
		$nameAttribute.Value = $variableName
		$environmentVariable.Attributes.Append($nameAttribute)
		
		$valueAttribute = $config.CreateAttribute("value")
		$valueAttribute.Value = $variableValue
		$environmentVariable.Attributes.Append($valueAttribute)

		$environmentVariablesNode.AppendChild($environmentVariable)
	}else {
		Write-Console $variableName "already exists in config, not overwriting"
	}
}

function New-AppRoot($appDirectory, $iisUser){
	# Create the necessary directories for the app
	$logDirectory = "$appDirectory\logs"

	if(!(Test-Path $appDirectory)) {
		Write-Console "Creating application directory: $appDirectory."
		mkdir $appDirectory | Out-Null
	}else{
		Write-Console "Application directory: $appDirectory exists."
	}

	
	if(!(Test-Path $logDirectory)) {
		Write-Console "Creating applciation log directory: $logDirectory."
		mkdir $logDirectory | Out-Null
		Write-Console "Setting Write and Read access for $iisUser on $logDirectory."
		$acl = (Get-Item $logDirectory).GetAccessControl('Access')
		$writeAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($iisUser, "Write", "ContainerInherit,ObjectInherit", "None", "Allow")
		$readAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($iisUser, "Read", "ContainerInherit,ObjectInherit", "None", "Allow")
		$acl.AddAccessRule($writeAccessRule)
		$acl.AddAccessRule($readAccessRule)
		Set-Acl -Path $logDirectory $acl
	}else{
		Write-Console "Log directory: $logDirectory exisits"
	}
}

function New-AppPool($appName, $userName, $credential){
	Set-Location IIS:\AppPools
	if(!(Test-Path $appName -PathType Container))
	{
		Write-Console "AppPool $appName does not exist...creating."
		$appPool = New-WebAppPool $appName
		$appPool | Set-ItemProperty -Name "managedRuntimeVersion" -Value ""
		
	}else{
		Write-Console "AppPool: $appName exists."
		$appPool = Get-Item $appName
	}

	if(![string]::IsNullOrEmpty($userName) -and $credential -ne $null)
	{
		$appPool.processModel.userName = $userName
		$appPool.processModel.password = $credential.GetNetworkCredential().Password
		$appPool.processModel.identityType = 3
		$appPool.processModel.loaduserprofile = $true
		$appPool | Set-Item
		$appPool.Stop()
		Invoke-WaitForWebAppPoolToChangeState -name $appPool.Name -state "Stopped"
	}
	$appPool.Start()
	Invoke-WaitForWebAppPoolToChangeState -name $appPool.Name -state "Started"
}

function New-Site($appName, $portNumber, $appDirectory, $hostHeader){
	cd IIS:\Sites

	if(!(Test-Path $appName -PathType Container))
	{
		Write-Console "WebSite $appName does not exist...creating."
		$webSite = New-Website -Name $appName -Port $portNumber -Ssl -PhysicalPath $appDirectory -ApplicationPool $appName -HostHeader $hostHeader
	
		Write-Console "Assigning certificate..."
		$cert = Get-Item Cert:\LocalMachine\My\$sslCertificateThumbprint
		Set-Location IIS:\SslBindings
		$sslBinding = "0.0.0.0!$portNumber"
		if(!(Test-Path $sslBinding)){
			$cert | New-Item $sslBinding
		}
	}
}

function New-App($appName, $siteName, $appDirectory){
	Set-Location IIS:\
	Write-Console "Creating web application: $webApp"
	New-WebApplication -Name $appName -Site $siteName -PhysicalPath $appDirectory -ApplicationPool $appName -Force
}

function Publish-WebSite($zipPackage, $appDirectory, $appName, $overwriteWebConfig){
	# Extract the app into the app directory
	Write-Console "Extracting $zipPackage to $appDirectory."

	try{
		Stop-WebAppPool -Name $appName
		Invoke-WaitForWebAppPoolToChangeState -name $appName -state "Stopped"
	}catch [System.InvalidOperationException]{
		Write-Console "AppPool $appName is already stopped, continuing."
	}

	Start-Sleep -Seconds 3
	$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPackage)
	foreach($item in $archive.Entries)
	{
		$itemTargetFilePath = [System.IO.Path]::Combine($appDirectory, $item.FullName)
		$itemDirectory = [System.IO.Path]::GetDirectoryName($itemTargetFilePath)
		$overwrite = $true

		if(!(Test-Path $itemDirectory)){
			New-Item -ItemType Directory -Path $itemDirectory | Out-Null
		}

		if(!(Test-IsDirectory $itemTargetFilePath)){
			if($itemTargetFilePath.EndsWith("web.config")){
				$overwrite = $overwriteWebConfig
			}
			try{
				Write-Console "......Extracting $itemTargetFilePath..."
				[System.IO.Compression.ZipFileExtensions]::ExtractToFile($item, $itemTargetFilePath, $overwrite)
			}catch [System.Management.Automation.MethodInvocationException]{
				Write-Console "......$itemTargetFilePath exists, not overwriting..."
				$errorId = $_.FullyQualifiedErrorId
				if($errorId -ne "IOException"){
					throw $_.Exception
				}
			}
		}
	}
	$archive.Dispose()
	Start-WebAppPool -Name $appName
	Invoke-WaitForWebAppPoolToChangeState -name $appName -state "Started"
}

function Test-IsDirectory($path)
{
	if((Test-Path $path) -and (Get-Item $path) -is [System.IO.DirectoryInfo]){
		return $true
	}
	return $false
}

function Set-EnvironmentVariables($appDirectory, $environmentVariables){
	Write-Console "Writing environment variables to config..."
	$webConfig = [xml](Get-Content $appDirectory\web.config)
	foreach ($variable in $environmentVariables.GetEnumerator()){
		Add-EnvironmentVariable $variable.Name $variable.Value $webConfig
	}

	$webConfig.Save("$appDirectory\web.config")
}

function Get-EncryptedString($signingCert, $stringToEncrypt){
	$encryptedString = [System.Convert]::ToBase64String($signingCert.PublicKey.Key.Encrypt([System.Text.Encoding]::UTF8.GetBytes($stringToEncrypt), $true))
	return "!!enc!!:" + $encryptedString
}

function Get-InstalledApps
{
    if ([IntPtr]::Size -eq 4) {
        $regpath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    }
    else {
        $regpath = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    }
    Get-ItemProperty $regpath | .{process{if($_.DisplayName -and $_.UninstallString) { $_ } }} | Select DisplayName, Publisher, InstallDate, DisplayVersion, UninstallString |Sort DisplayName
}

function Test-Prerequisite($appName, $minVersion)
{
    $installedAppResults = Get-InstalledApps | where {$_.DisplayName -like $appName}
    if($installedAppResults -eq $null){
        return $false;
    }

    if($minVersion -eq $null)
    {
        return $true;
    }

    $minVersionAsSystemVersion = [System.Version]$minVersion
    Foreach($version in $installedAppResults)
    {
        $installedVersion = [System.Version]$version.DisplayVersion
        if($installedVersion -ge $minVersionAsSystemVersion)
        {
            return $true;
        }
    }
}


function Test-PrerequisiteExact($appName, $supportedVersion)
{
    $installedAppResults = Get-InstalledApps | where {$_.DisplayName -like $appName}
    if($installedAppResults -eq $null){
        return $false;
    }

    if($supportedVersion -eq $null)
    {
        return $true;
    }

    $supportedVersionAsSystemVersion = [System.Version]$supportedVersion

    Foreach($version in $installedAppResults)
    {
        $installedVersion = [System.Version]$version.DisplayVersion
        if($installedVersion -eq $supportedVersionAsSystemVersion)
        {
            return $true;
        }
    }
}

function Get-CouchDbRemoteInstallationStatus($couchDbServer, $minVersion)
{
    try
    {
        $couchVersionResponse = Invoke-RestMethod -Method Get -Uri $couchDbServer 
    } catch {
        Write-Console "CouchDB not found on $couchDbServer"
    }

    if($couchVersionResponse)
    {
        $installedVersion = [System.Version]$couchVersionResponse.version
        $minVersionAsSystemVersion = [System.Version]$minVersion
        Write-Console "Found CouchDB version $installedVersion installed on $couchDbServer"
        if($installedVersion -ge $minVersionAsSystemVersion)
        {
            return "Installed"
        }else {
            return "MinVersionNotMet"
        }
    }
    return "NotInstalled"
}

function Get-AccessToken($authUrl, $clientId, $scope, $secret)
{
    $url = "$authUrl/connect/token"
    $body = @{
        client_id = "$clientId"
        grant_type = "client_credentials"
        scope = "$scope"
        client_secret = "$secret"
    }
    $accessTokenResponse = Invoke-RestMethod -Method Post -Uri $url -Body $body
    return $accessTokenResponse.access_token
}

function Add-ApiRegistration($authUrl, $body, $accessToken)
{
    $url = "$authUrl/api/apiresource"
    $headers = @{"Accept" = "application/json"}
    if($accessToken){
        $headers.Add("Authorization", "Bearer $accessToken")
    }
    $registrationResponse = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType "application/json" -Headers $headers
    return $registrationResponse.apiSecret    
}

function Add-ClientRegistration($authUrl, $body, $accessToken)
{
    $url = "$authUrl/api/client"
    $headers = @{"Accept" = "application/json"}
    if($accessToken){
        $headers.Add("Authorization", "Bearer $accessToken")
    }
    $registrationResponse = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType "application/json" -Headers $headers
    return $registrationResponse.clientSecret
}

function Get-CurrentScriptDirectory()
{
	return Split-Path $script:MyInvocation.MyCommand.Path
}

function Get-InstallationSettings($configSection)
{
	$installationConfig = [xml](Get-Content install.config)
	$sectionSettings = $installationConfig.installation.settings.scope | where {$_.name -eq $configSection}
	$installationSettings = @{}

	foreach($variable in $sectionSettings.variable){
		if($variable.name -and $variable.value){
			$installationSettings.Add($variable.name, $variable.value)
		}
	}

	$commonSettings = $installationConfig.installation.settings.scope | where {$_.name -eq "common"}
	foreach($variable in $commonSettings.variable){
		if($variable.name -and $variable.value -and !$installationSettings.Contains($variable.name)){
			$installationSettings.Add($variable.name, $variable.value)
		}
	}
	
	try{
		$encryptionCertificateThumbprint = $installationSettings.encryptionCertificateThumbprint
		$encryptionCertificate = Get-EncryptionCertificate $encryptionCertificateThumbprint
	}catch{
		Write-Error "Could not get encryption certificte with thumbprint $encryptionCertificateThumbprint. Please verify that the encryptionCertificateThumbprint setting in install.config contains a valid thumbprint for a certificate in the Local Machine Personal store."
		throw $_.Exception
	}

	$installationSettingsDecrypted = @{}
	foreach($key in $installationSettings.Keys){
		$value = $installationSettings[$key]
		if($value.StartsWith("!!enc!!:"))
		{
			$value = Get-DecryptedString $encryptionCertificate $value
		}
		$installationSettingsDecrypted.Add($key, $value)
	}
	
	return $installationSettingsDecrypted
}

function Add-InstallationSetting($configSection, $configSetting, $configValue)
{
	$currentDirectory = Get-CurrentScriptDirectory
	$configFile = "install.config"
	$installationConfig = [xml](Get-Content "$currentDirectory\$configFile")
	$sectionSettings = $installationConfig.installation.settings.scope | where {$_.name -eq $configSection}
	$existingSetting = $sectionSettings.variable | where {$_.name -eq $configSetting}
	if($existingSetting -eq $null){
		$setting = $installationConfig.CreateElement("variable")
		
		$nameAttribute = $installationConfig.CreateAttribute("name")
		$nameAttribute.Value = $configSetting
		$setting.Attributes.Append($nameAttribute)

		$valueAttribute = $installationConfig.CreateAttribute("value")
		$valueAttribute.Value = $configValue
		$setting.Attributes.Append($valueAttribute)

		$sectionSettings.AppendChild($setting)
	}else{
		$existingSetting.value = $configValue
	}
	$installationConfig.Save("$currentDirectory\$configFile")
}

function Add-SecureInstallationSetting($configSection, $configSetting, $configValue, $encryptionCertificate)
{
	$encryptedConfigValue = Get-EncryptedString $encryptionCertificate $configValue
	Add-InstallationSetting $configSection $configSetting $encryptedConfigValue
}

function Get-EncryptionCertificate($encryptionCertificateThumbprint)
{
	return Get-Certificate $encryptionCertificateThumbprint
}

function Get-Certificate($certificateThumbprint)
{
	$certificateThumbprint = $certificateThumbprint -replace '[^a-zA-Z0-9]', ''
	return Get-Item Cert:\LocalMachine\My\$certificateThumbprint -ErrorAction Stop
}

function Get-DecryptedString($encryptionCertificate, $encryptedString){
	if($encryptedString.Contains("!!enc!!:")){
		$cleanedEncryptedString = $encryptedString.Replace("!!enc!!:","")
		$clearTextValue = [System.Text.Encoding]::UTF8.GetString($encryptionCertificate.PrivateKey.Decrypt([System.Convert]::FromBase64String($cleanedEncryptedString), $true))
		return $clearTextValue
	}else{
		return $encryptedString
	}
}

function Get-CertsFromLocation($certLocation){
    $currentLocation = Get-Location
    Set-Location $certLocation
    $certs = Get-ChildItem
    Set-Location $currentLocation
    return $certs
}

function Get-CertThumbprint($certs, $selectionNumber){
    $selectedCert = $certs[$selectionNumber-1]
    $certThumbrint = $selectedCert.Thumbprint
    return $certThumbrint
}

function Test-IsRunAsAdministrator()
{
	$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
	return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ServiceUserToDiscovery($userName, $connString)
{

    $query = "DECLARE @IdentityID int;
                DECLARE @DiscoveryServiceUserRoleID int;

				SELECT @IdentityID = IdentityID FROM CatalystAdmin.IdentityBASE WHERE IdentityNM = @userName;
				IF (@IdentityID IS NULL)
				BEGIN
					print ''-- Adding Identity'';
					INSERT INTO CatalystAdmin.IdentityBASE (IdentityNM) VALUES (@userName);
					SELECT @IdentityID = SCOPE_IDENTITY();
				END

				SELECT @DiscoveryServiceUserRoleID = RoleID FROM CatalystAdmin.RoleBASE WHERE RoleNM = 'DiscoveryServiceUser';
				IF (NOT EXISTS (SELECT 1 FROM CatalystAdmin.IdentityRoleBASE WHERE IdentityID = @IdentityID AND RoleID = @DiscoveryServiceUserRoleID))
				BEGIN
					print ''-- Assigning Discovery Service user'';
					INSERT INTO CatalystAdmin.IdentityRoleBASE (IdentityID, RoleID) VALUES (@IdentityID, @DiscoveryServiceUserRoleID);
				END"
	Invoke-Sql $connString $query @{userName=$userName} | Out-Null
}

function Invoke-Sql($connectionString, $sql, $parameters=@{}){    
    $connection = New-Object System.Data.SqlClient.SQLConnection($connectionString)
    $command = New-Object System.Data.SqlClient.SqlCommand($sql, $connection)
	
    try {
		foreach($p in $parameters.Keys){		
		  $command.Parameters.AddWithValue("@$p",$parameters[$p])
		 }

        $connection.Open()    
        $command.ExecuteNonQuery()
        $connection.Close()        
    }catch [System.Data.SqlClient.SqlException] {
        Write-Error "An error ocurred while executing the command. Please ensure the connection string is correct and the identity database has been setup. Connection String: $($connectionString). Error $($_.Exception.Message)"  -ErrorAction Stop
    }    
}

function Write-Success($message){
	Write-Host $message -ForegroundColor Green
}

function Write-Console($message){
	Write-Host $message -ForegroundColor Gray
}

Export-ModuleMember -function Add-EnvironmentVariable
Export-ModuleMember -function New-AppRoot
Export-ModuleMember -function New-AppPool
Export-ModuleMember -function New-Site
Export-ModuleMember -function New-App
Export-ModuleMember -function Publish-WebSite
Export-ModuleMember -function Set-EnvironmentVariables
Export-ModuleMember -function Get-EncryptedString
Export-ModuleMember -function Test-Prerequisite
Export-ModuleMember -function Test-PrerequisiteExact
Export-ModuleMember -function Get-CouchDbRemoteInstallationStatus
Export-ModuleMember -function Get-AccessToken
Export-ModuleMember -function Add-ApiRegistration
Export-ModuleMember -function Add-ClientRegistration
Export-ModuleMember -function Get-CurrentScriptDirectory
Export-ModuleMember -function Get-InstallationSettings
Export-ModuleMember -function Add-InstallationSetting
Export-ModuleMember -function Add-SecureInstallationSetting
Export-ModuleMember -function Get-EncryptionCertificate
Export-ModuleMember -function Get-DecryptedString
Export-ModuleMember -Function Get-Certificate
Export-ModuleMember -Function Get-CertsFromLocation
Export-ModuleMember -Function Get-CertThumbprint
Export-ModuleMember -Function Write-Success
Export-ModuleMember -Function Write-Console
Export-ModuleMember -Function Test-IsRunAsAdministrator
Export-ModuleMember -Function Add-ServiceUserToDiscovery
Export-ModuleMember -Function Invoke-Sql