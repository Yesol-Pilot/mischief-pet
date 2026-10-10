# Runner-only sideload QA. No source/build edits, private-key export, portable launch,
# renderer injection, Node inspector, or real license activation. Workflow embeds this file.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$AppxAsset,
    [Parameter(Mandatory)][string]$AppxSha256,
    [Parameter(Mandatory)][string]$EvidenceDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$identity = 'NeoGenesis.MischiefPet.SideloadTest'
$subject = 'CN=MischiefPetSideloadTest'
$asarHash = 'abfc7dc5785d357a35afa7d42214e7897ea50a571e57e8d9979aa04930d61669'
$nativeHash = 'dcb3048bba5cf115aa19172f091cf005f8be9d39fd42dfb5ea25103318784a44'
$asarRelative = 'app\resources\app.asar'
$nativeRelative = 'app\resources\app.asar.unpacked\node_modules\@koromix\koffi-win32-x64\win32_x64\koffi.node'
${nativeZipRelative} = 'app/resources/app.asar.unpacked/node_modules/@koromix/koffi-win32-x64/win32_x64/koffi.node'
$names = @('runner_guard','private_draft_input','unsigned_payload','certificate_sign_verify','install','installed_payload','interactive_desktop','network_capture','shell_launch','process_paths','pet_window_screenshot','hide_shortcut','manager_ui','welcome_complete','store_purchase_ui','plus_activation_ui','store_startup_state','packaged_appdata','close_to_tray','clean_quit','no_update_request','wack','uninstall','cleanup_processes','cleanup_package','cleanup_certificates','cleanup_files')
$checks = [ordered]@{}
foreach ($name in $names) { $checks[$name] = [ordered]@{ status='NOTEXERCISED'; reason='Prerequisites not exercised'; details=$null } }
$receipt = [ordered]@{
    schema_version=1; started_at=[DateTime]::UtcNow.ToString('o'); result='INCOMPLETE'
    provenance=[ordered]@{ repository=$env:GITHUB_REPOSITORY; run_id=$env:GITHUB_RUN_ID; run_attempt=$env:GITHUB_RUN_ATTEMPT; workflow_ref=$env:GITHUB_WORKFLOW_REF; workflow_sha=$env:GITHUB_WORKFLOW_SHA; dispatch_sha=$env:GITHUB_SHA; release_tag=$ReleaseTag; appx_asset=$AppxAsset; appx_sha256=$AppxSha256; harness_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant(); accepted_asar_sha256=$asarHash; accepted_native_sha256=$nativeHash }
    checks=$checks; screenshots=@(); commands=@(); limitations=@(
        'Sideload test identity only; not a Partner Center identity or Store certification claim.',
        'AppX 1.6.0.0 maps app version 0.6.0 as (major+1).minor.patch.0; the frozen application version is unchanged.',
        'No real key, checkout, entitlement activation or payment is attempted. Activation UI is tested with empty input only.',
        'No GUI or missing WACK is UNAVAILABLE with observed reason; no simulated desktop, synthetic screenshot or substitute test.',
        'GUI uses Windows UI Automation and real SendInput only. Shell AppsFolder launches the installed package; no inspector or portable bypass.',
        'Screenshots capture the actual ephemeral hosted runner desktop, not an illustration. Appdata receipts record paths/file names/hashes, never save contents.'
    )
}
$certThumb = $null; $trustOwned = $false; $packageOwned = $false; $package = $null
$work = $null; $installRoot = $null; $packageData = $null; $petHandles = @(); $managerHandle = [IntPtr]::Zero
$ownedProcesses = @{}; $gui = $false; $safeRunner = $false; $signatureReady = $false
$networkStart = $null; $auditBackup = $null; $auditEnabled = $false
$plainSave = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'neogenesis-mischief-pet'
function Protect-Text([string]$Text) {
    foreach ($token in @($env:GH_TOKEN,$env:GITHUB_TOKEN)) { if ($token) { $Text=$Text.Replace($token,'<TOKEN>') } }
    if ($env:USERPROFILE) { $Text=$Text.Replace($env:USERPROFILE,'<RUNNER_PROFILE>') }
    if ($env:RUNNER_TEMP) { $Text=$Text.Replace($env:RUNNER_TEMP,'<RUNNER_TEMP>') }
    return $Text
}
function Set-Check([string]$Name,[string]$Status,[string]$Reason,$Details=$null) {
    $checks[$Name] = [ordered]@{status=$Status; reason=(Protect-Text $Reason); details=$Details}
}
function Check([string]$Name,[scriptblock]$Action) {
    try { $details = & $Action; Set-Check $Name 'PASS' 'Observed check completed' $details; return $true }
    catch { Set-Check $Name 'FAIL' $_.Exception.Message; return $false }
}
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Command([string]$File,[string[]]$Arguments,[bool]$AllowFailure=$false) {
    $started=[DateTime]::UtcNow.ToString('o')
    $lines=@(& $File @Arguments 2>&1); $code=$LASTEXITCODE
    $text=Protect-Text (($lines | ForEach-Object { $_.ToString() }) -join "`n")
    $receipt.commands += [ordered]@{ executable=(Protect-Text $File); arguments=@($Arguments | ForEach-Object { Protect-Text $_ }); started_at=$started; exit_code=$code; output=$text }
    if ($code -ne 0 -and -not $AllowFailure) { throw "Command failed ($code): $File; $text" }
    return $text
}
function Wait-For([scriptblock]$Predicate,[int]$Seconds=30) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Predicate) { return }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Observed condition did not become true within $Seconds seconds"
}
function Get-OwnedProcesses {
    if (-not $installRoot) { return @() }
    $all=@(Get-CimInstance Win32_Process)
    $prefix=$installRoot.TrimEnd('\')+'\'
    foreach ($p in $all) {
        if ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $ownedProcesses[[int]$p.ProcessId]=$p.CreationDate.ToUniversalTime().Ticks }
    }
    # Track child lifetimes as well as executable paths; never kill a reused PID.
    do {
        $added=$false
        foreach ($p in $all) {
            if ($ownedProcesses.ContainsKey([int]$p.ParentProcessId) -and -not $ownedProcesses.ContainsKey([int]$p.ProcessId)) {
                $parent=$all | Where-Object { $_.ProcessId -eq $p.ParentProcessId } | Select-Object -First 1
                if ($parent -and $parent.CreationDate.ToUniversalTime().Ticks -eq $ownedProcesses[[int]$parent.ProcessId]) { $ownedProcesses[[int]$p.ProcessId]=$p.CreationDate.ToUniversalTime().Ticks; $added=$true }
            }
        }
    } while ($added)
    return @($all | Where-Object { $ownedProcesses.ContainsKey([int]$_.ProcessId) -and $_.CreationDate.ToUniversalTime().Ticks -eq $ownedProcesses[[int]$_.ProcessId] })
}
function Process-Receipt {
    return @(Get-OwnedProcesses | ForEach-Object { [ordered]@{ pid=$_.ProcessId; parent_pid=$_.ParentProcessId; path=(Protect-Text $_.ExecutablePath); creation_utc=$_.CreationDate.ToUniversalTime().ToString('o'); session_id=$_.SessionId } })
}
function App-Windows {
    $pids=@(Get-OwnedProcesses | ForEach-Object { [uint32]$_.ProcessId })
    return @([MischiefQa.Desktop]::Windows() | Where-Object { $_.ClassName -eq 'Chrome_WidgetWin_1' -and $pids -contains $_.ProcessId })
}
function Window-Receipt($Windows) {
    return @($Windows | ForEach-Object { [ordered]@{ handle=$_.Handle.ToInt64(); pid=$_.ProcessId; title=$_.Title; visible=$_.Visible; x=$_.Left; y=$_.Top; width=$_.Width; height=$_.Height } })
}
function Screenshot([string]$Name) {
    $screen=[Windows.Forms.SystemInformation]::VirtualScreen
    Assert-True ($screen.Width -gt 0 -and $screen.Height -gt 0) 'Desktop has no drawable bounds'
    $bitmap=[Drawing.Bitmap]::new($screen.Width,$screen.Height)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $path=Join-Path $EvidenceDirectory "$Name.png"
    try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$screen.Size); $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
    $row=[ordered]@{ file="$Name.png"; sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant(); captured_at=[DateTime]::UtcNow.ToString('o'); width=$screen.Width; height=$screen.Height; method='GDI CopyFromScreen of actual hosted runner desktop' }
    $receipt.screenshots += $row
    return $row
}
function Click-Element($Element) {
    Assert-True ($null -ne $Element) 'Requested UI Automation element is absent'
    $current=$Element.Current
    Assert-True (-not $current.IsOffscreen -and $current.IsEnabled) 'UI element is not visible/enabled'
    $r=$current.BoundingRectangle
    Assert-True ($r.Width -gt 0 -and $r.Height -gt 0) 'UI element has no clickable bounds'
    [MischiefQa.Desktop]::Click([int]($r.Left+$r.Width/2),[int]($r.Top+$r.Height/2))
}
function Find-UI([IntPtr]$Handle,[string]$Pattern,[switch]$Password,[switch]$IncludeOffscreen) {
    # Chromium builds its accessibility tree lazily after the first UIA query; callers retry.
    try {
        $root=[Windows.Automation.AutomationElement]::FromHandle($Handle)
        $elements=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
        foreach ($e in $elements) {
            $c=$e.Current
            if (($IncludeOffscreen -or -not $c.IsOffscreen) -and $c.Name -match $Pattern -and (-not $Password -or $c.IsPassword)) { return $e }
        }
    } catch [Windows.Automation.ElementNotAvailableException] { }
    return $null
}
function Find-Checkbox([IntPtr]$Handle,[string]$Pattern) {
    $root=[Windows.Automation.AutomationElement]::FromHandle($Handle)
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::CheckBox)
    foreach($element in $root.FindAll([Windows.Automation.TreeScope]::Descendants,$condition)) {
        if($element.Current.Name -match $Pattern){return $element}
    }
    return $null
}
function Reveal-UI([IntPtr]$Handle,[string]$Pattern,[switch]$Password,[int]$Seconds=30) {
    # Real mouse-wheel input scrolls below-the-fold manager controls fully into the window.
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $window=@(App-Windows | Where-Object { $_.Handle -eq $Handle -and $_.Visible })
        Assert-True ($window.Count -eq 1) 'Manager window is not visible'
        $w=$window[0]; $cx=[int]($w.Left+$w.Width/2); $cy=[int]($w.Top+$w.Height/2)
        $e=Find-UI $Handle $Pattern -Password:$Password -IncludeOffscreen
        if ($e) {
            $r=$e.Current.BoundingRectangle; $y=$r.Top+$r.Height/2
            if (-not $e.Current.IsOffscreen -and $y -ge $w.Top+48 -and $y -le $w.Top+$w.Height-16) { return $e }
            [MischiefQa.Desktop]::Wheel($cx,$cy,$(if ($y -lt $w.Top+48) { 120 } else { -120 }))
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}
function Save-Inventory([string]$Directory) {
    # The running app keeps Chromium databases locked; record them without reading contents.
    return @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $file=$_; $relative=[IO.Path]::GetRelativePath($Directory,$file.FullName)
        try { [ordered]@{ relative_path=$relative; bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
        catch { [ordered]@{ relative_path=$relative; bytes=$file.Length; sha256=$null; locked_by_running_app=$true } }
    })
}
function Read-AsarAppVersion([string]$File) {
    # Read only the actual installed ASAR package.json; do not extract or modify the archive.
    $stream=[IO.File]::OpenRead($File)
    try {
        $prefix=[byte[]]::new(16); $stream.ReadExactly($prefix,0,16)
        $headerSize=[BitConverter]::ToUInt32($prefix,4)
        $jsonSize=[BitConverter]::ToUInt32($prefix,12)
        Assert-True ($headerSize -ge 8 -and $headerSize -le 33554432 -and $jsonSize -le $headerSize-8) 'Invalid ASAR header bounds'
        $header=[byte[]]::new($jsonSize); $stream.ReadExactly($header,0,$header.Length)
        $tree=[Text.Encoding]::UTF8.GetString($header) | ConvertFrom-Json
        $entry=$tree.files.'package.json'
        Assert-True ($entry.size -gt 0 -and $entry.size -le 1048576) 'Invalid ASAR package.json size'
        $offset=[int64]::Parse($entry.offset,[Globalization.CultureInfo]::InvariantCulture)
        Assert-True ($offset -ge 0 -and 8+$headerSize+$offset+$entry.size -le $stream.Length) 'Invalid ASAR package.json offset'
        $stream.Seek(8+$headerSize+$offset,[IO.SeekOrigin]::Begin) | Out-Null
        $data=[byte[]]::new($entry.size); $stream.ReadExactly($data,0,$data.Length)
        $metadata=[Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
        return $metadata.version
    } finally { $stream.Dispose() }
}
function Find-ZipEntryDecoded($Zip,[string]$RelativePath) {
    $wanted=$RelativePath.Replace('\','/').ToLowerInvariant()
    foreach ($entry in $Zip.Entries) {
        $decoded=[Uri]::UnescapeDataString($entry.FullName).ToLowerInvariant()
        if ($decoded -ceq $wanted) { return $entry }
    }
    return $null
}
try {
    $safeRunner = Check 'runner_guard' {
        Assert-True ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and $env:RUNNER_TEMP) 'Only ephemeral GitHub-hosted Actions runner is authorized'
        Assert-True ($AppxAsset -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.appx$' -and $AppxSha256 -cmatch '^[a-f0-9]{64}$') 'Exact AppX filename and lowercase SHA256 are required'
        Assert-True ($env:GH_TOKEN -and $env:GITHUB_REPOSITORY) 'Workflow default token and repository are required'
        Assert-True (-not (Test-Path -LiteralPath $plainSave)) 'Preexisting unvirtualized save path: refusing to launch or touch it'
        Assert-True (@(Get-AppxPackage -Name $identity).Count -eq 0) 'Preexisting test package: refusing to replace it'
        Assert-True (@(Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq $subject).Count -eq 0) 'Preexisting QA private certificate: refusing to touch it'
        Assert-True (@(Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq $subject).Count -eq 0) 'Preexisting QA trust certificate: refusing to touch it'
        $stale=@(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter "$identity*" -ErrorAction SilentlyContinue)
        Assert-True ($stale.Count -eq 0) 'Preexisting package appdata: refusing to launch or touch it'
        [ordered]@{ hosted_runner=$true; user_interactive=[Environment]::UserInteractive; session_id=(Get-Process -Id $PID).SessionId; os=[Environment]::OSVersion.VersionString; unvirtualized_save_path=(Protect-Text $plainSave); preexisting_save=$false; preexisting_package=$false; preexisting_package_data=$false; preexisting_certificates=$false }
    }
    if (-not $safeRunner) { throw 'Runner/input preflight failed; no application or certificate mutation authorized' }
    $EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
    $tempPrefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
    Assert-True ($EvidenceDirectory.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) 'Evidence must be inside supplied runner temp'
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    $work=Join-Path $env:RUNNER_TEMP ('mischief-appx-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $inputFile=Join-Path $work 'input.appx'; $signedFile=Join-Path $work 'signed.appx'
    $inputOK=Check 'private_draft_input' {
        $repo=(Command 'gh' @('repo','view',$env:GITHUB_REPOSITORY,'--json','isPrivate')) | ConvertFrom-Json
        # Draft releases are private/unpublished even when their repository is public.
        $release=(Command 'gh' @('release','view',$ReleaseTag,'--repo',$env:GITHUB_REPOSITORY,'--json','tagName,isDraft,assets')) | ConvertFrom-Json
        Assert-True ($release.isDraft -eq $true -and $release.tagName -ceq $ReleaseTag) 'Requested release is not the exact private draft'
        $assets=@($release.assets | Where-Object { $_.name -ceq $AppxAsset })
        Assert-True ($assets.Count -eq 1) 'Exact AppX asset must occur once in private draft'
        $receipt.provenance.release_asset=[ordered]@{ id=$assets[0].id; name=$assets[0].name; bytes=$assets[0].size; created_at=$assets[0].createdAt; updated_at=$assets[0].updatedAt; is_draft=$true; repository_private=$repo.isPrivate }
        Command 'gh' @('release','download',$ReleaseTag,'--repo',$env:GITHUB_REPOSITORY,'--pattern',$AppxAsset,'--dir',$work) | Out-Null
        Move-Item -LiteralPath (Join-Path $work $AppxAsset) -Destination $inputFile
        $actual=(Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -ceq $AppxSha256) 'Downloaded AppX SHA256 differs from authorized input'
        # Re-read draft/asset identity after download; never accept a concurrently published release.
        $after=(Command 'gh' @('release','view',$ReleaseTag,'--repo',$env:GITHUB_REPOSITORY,'--json','tagName,isDraft,assets')) | ConvertFrom-Json
        $same=@($after.assets | Where-Object { $_.name -ceq $AppxAsset -and $_.id -eq $assets[0].id -and $_.updatedAt -eq $assets[0].updatedAt })
        Assert-True ($after.isDraft -eq $true -and $after.tagName -ceq $ReleaseTag -and $same.Count -eq 1) 'Draft or asset changed during download'
        [ordered]@{ sha256=$actual; bytes=(Get-Item $inputFile).Length; draft_verified_before_and_after=$true }
    }
    if (-not $inputOK) { throw 'Authorized input unavailable' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $payloadOK=Check 'unsigned_payload' {
        $zip=[IO.Compression.ZipFile]::OpenRead($inputFile)
        try {
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $zip.Entries) {
                $name=$entry.FullName.Replace('\','/')
                Assert-True ($name -and -not $name.StartsWith('/') -and $name -notmatch '[:\x00]' -and $name.Split('/') -notcontains '..' -and $name.Split('/') -notcontains '.') "Unsafe AppX ZIP entry: $name"
                Assert-True ($seen.Add($name)) "Duplicate AppX ZIP entry: $name"
                Assert-True (($entry.ExternalAttributes -shr 16 -band 0xF000) -ne 0xA000) "Symlink AppX ZIP entry: $name"
            }
            Assert-True (-not $zip.GetEntry('AppxSignature.p7x')) 'Input must be unsigned placeholder-identity AppX'
            $manifestEntry=$zip.GetEntry('AppxManifest.xml'); Assert-True ($null -ne $manifestEntry) 'AppX manifest missing'
            $reader=[IO.StreamReader]::new($manifestEntry.Open()); try { [xml]$manifest=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $id=$manifest.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
            Assert-True ($id.GetAttribute('Name') -ceq $identity -and $id.GetAttribute('Publisher') -ceq $subject -and $id.GetAttribute('Version') -ceq '1.6.0.0' -and $id.GetAttribute('ProcessorArchitecture') -ceq 'x64') 'Unexpected AppX identity/publisher/version/architecture'
            $application=$manifest.SelectSingleNode('//*[local-name()="Application"]')
            Assert-True ($application.Id -ceq 'MischiefPet' -and $application.Executable.Replace('/','\') -ceq 'app\MischiefPet.exe' -and $application.EntryPoint -ceq 'Windows.FullTrustApplication') 'Unexpected full-trust application registration'
            Assert-True ($null -ne $manifest.SelectSingleNode('//*[local-name()="Capability" and @Name="runFullTrust"]')) 'runFullTrust capability missing'
            $languages=@($manifest.SelectNodes('//*[local-name()="Resource" and @Language]') | ForEach-Object { $_.Language.ToLowerInvariant() })
            Assert-True ($languages -contains 'en-us' -and $languages -contains 'ko-kr') 'Required en-US/ko-KR resources absent'
            $startup=$manifest.SelectSingleNode('//*[local-name()="StartupTask"]')
            Assert-True ($null -ne $startup -and $startup.TaskId -ceq 'MischiefPetStartupTask' -and $startup.Enabled -ceq 'false') 'Startup task must be opt-in and disabled by default'
            $extension=$startup.ParentNode
            Assert-True ($extension.GetAttribute('Category') -ceq 'windows.startupTask' -and $extension.GetAttribute('Parameters','http://schemas.microsoft.com/appx/manifest/uap/windows10/10') -ceq '--autostart') 'Startup task registration differs'
            $policyEntry=Find-ZipEntryDecoded $zip 'app/resources/commerce-store.json'
            Assert-True ($null -ne $policyEntry) 'Store-only outer commerce policy missing'
            $reader=[IO.StreamReader]::new($policyEntry.Open()); try { $policy=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            Assert-True ($policy.purchaseLinks -eq $false) 'Store purchase links must be disabled'
            $hashes=@()
            $payloads=@(
                [pscustomobject]@{path=$asarRelative; zipPath=$asarRelative; hash=$asarHash}
                [pscustomobject]@{path=$nativeRelative; zipPath=$nativeZipRelative; hash=$nativeHash}
            )
            foreach ($pair in $payloads) {
                $entry=Find-ZipEntryDecoded $zip $pair.zipPath
                Assert-True ($null -ne $entry) "Accepted payload absent: $($pair.path)"
                $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
                try { $actual=[Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() } finally { $sha.Dispose(); $stream.Dispose() }
                Assert-True ($actual -ceq $pair.hash) "Accepted payload hash differs: $($pair.path)"
                $hashes += [ordered]@{path=$pair.path; zip_path=$entry.FullName; sha256=$actual}
            }
            [ordered]@{ identity=$id.GetAttribute('Name'); publisher=$id.GetAttribute('Publisher'); version=$id.GetAttribute('Version'); architecture=$id.GetAttribute('ProcessorArchitecture'); application_id=$application.Id; executable=$application.Executable; entrypoint=$application.EntryPoint; languages=$languages; zip_entries=$zip.Entries.Count; zip_traversal_guard='All entries checked; no extraction'; accepted_payload=$hashes }
        } finally { $zip.Dispose() }
    }
    if (-not $payloadOK) { throw 'Unsigned AppX contract failed' }
    $signatureReady=Check 'certificate_sign_verify' {
        $kits=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        $signTool=Get-ChildItem -LiteralPath $kits -Filter signtool.exe -Recurse | Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName -Descending | Select-Object -First 1
        Assert-True ($null -ne $signTool) 'Windows SDK x64 signtool.exe unavailable'
        $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(1)
        $script:certThumb=$cert.Thumbprint
        $publicFile=Join-Path $work 'public.cer'
        Export-Certificate -Cert $cert -FilePath $publicFile -Type CERT | Out-Null
        Import-Certificate -FilePath $publicFile -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
        $script:trustOwned=$true
        Copy-Item -LiteralPath $inputFile -Destination $signedFile
        Command $signTool.FullName @('sign','/fd','SHA256','/sha1',$cert.Thumbprint,'/s','My',$signedFile) | Out-Null
        Command $signTool.FullName @('verify','/pa','/v',$signedFile) | Out-Null
        $signature=Get-AuthenticodeSignature -LiteralPath $signedFile
        Assert-True ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Thumbprint -eq $cert.Thumbprint) 'Signed AppX Authenticode verification failed'
        Assert-True ((Get-FileHash $inputFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $AppxSha256) 'Original unsigned input mutated'
        [ordered]@{ sdk_signtool=$signTool.FullName; subject=$subject; thumbprint=$cert.Thumbprint; private_key_exported=$false; key_export_policy='NonExportable'; public_cert_exported_only=$true; signed_copy_sha256=(Get-FileHash $signedFile -Algorithm SHA256).Hash.ToLowerInvariant(); authenticode_status=$signature.Status.ToString() }
    }
    if (-not $signatureReady) { throw 'Runner signing failed' }
    $installed=Check 'install' {
        # Set ownership before registration so partial registration is also cleaned up.
        $script:packageOwned=$true
        Add-AppxPackage -Path $signedFile -ErrorAction Stop
        $found=@(Get-AppxPackage -Name $identity)
        Assert-True ($found.Count -eq 1) 'Installed package must occur exactly once'
        $script:package=$found[0]; $script:installRoot=$package.InstallLocation
        $script:packageData=Join-Path $env:LOCALAPPDATA ('Packages\'+$package.PackageFamilyName)
        Assert-True ($package.Version.ToString() -ceq '1.6.0.0' -and $package.Publisher -ceq $subject) 'Installed package identity differs'
        $receipt.provenance.installed_package=[ordered]@{ full_name=$package.PackageFullName; family_name=$package.PackageFamilyName; install_location=$package.InstallLocation; application_id='MischiefPet'; shell_target=('shell:AppsFolder\'+$package.PackageFamilyName+'!MischiefPet') }
        $receipt.provenance.installed_package
    }
    if (-not $installed) { throw 'AppX registration failed' }
    Check 'installed_payload' {
        $rows=@()
        $payloads=@(
            [pscustomobject]@{path=$asarRelative; hash=$asarHash}
            [pscustomobject]@{path=$nativeRelative; hash=$nativeHash}
        )
        foreach ($pair in $payloads) {
            $file=Join-Path $installRoot $pair.path
            $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ($actual -ceq $pair.hash) "Installed accepted payload differs: $($pair.path)"
            $rows += [ordered]@{installed_relative_path=$pair.path; actual_sha256=$actual; accepted_sha256=$pair.hash}
        }
        $appVersion=Read-AsarAppVersion (Join-Path $installRoot $asarRelative)
        Assert-True ($appVersion -ceq '0.6.0') 'Frozen application own version differs from 0.6.0'
        [ordered]@{ accepted_payload=$rows; observed_app_version=$appVersion; appx_version=$package.Version.ToString(); version_mapping='(major+1).minor.patch.0' }
    } | Out-Null
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace MischiefQa {
  public sealed class Window {
    public IntPtr Handle; public uint ProcessId; public string Title, ClassName;
    public bool Visible; public int Left, Top, Width, Height;
  }
  public static class Desktop {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort key,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mouse; [FieldOffset(0)] public KEYBDINPUT key; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION data; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p,IntPtr arg);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,INPUT[] data,int size);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    public static int InputDesktopError() { var h=OpenInputDesktop(0,false,0x101); if(h==IntPtr.Zero)return Marshal.GetLastWin32Error(); CloseDesktop(h); return 0; }
    public static Window[] Windows() {
      var list=new List<Window>(); EnumWindows((h,p)=>{ uint id; GetWindowThreadProcessId(h,out id); RECT r; GetWindowRect(h,out r);
        var title=new StringBuilder(1024); var cls=new StringBuilder(256); GetWindowText(h,title,title.Capacity); GetClassName(h,cls,cls.Capacity);
        list.Add(new Window {Handle=h,ProcessId=id,Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(h),Left=r.L,Top=r.T,Width=r.R-r.L,Height=r.B-r.T}); return true; },IntPtr.Zero); return list.ToArray();
    }
    static INPUT Key(ushort key,bool up) { return new INPUT {type=1,data=new UNION {key=new KEYBDINPUT {key=key,flags=up?2u:0u}}}; }
    static void Send(INPUT[] data) { if(SendInput((uint)data.Length,data,Marshal.SizeOf(typeof(INPUT)))!=data.Length)throw new InvalidOperationException("SendInput failed: "+Marshal.GetLastWin32Error()); }
    public static void HideShortcut() { try { Send(new[]{Key(0x11,false),Key(0x10,false),Key(0x48,false),Key(0x48,true),Key(0x10,true),Key(0x11,true)}); } finally { Send(new[]{Key(0x48,true),Key(0x10,true),Key(0x11,true)}); } }
    public static void Click(int x,int y) { if(!SetCursorPos(x,y))throw new InvalidOperationException("SetCursorPos failed"); Send(new[]{new INPUT {type=0,data=new UNION {mouse=new MOUSEINPUT {flags=2}}},new INPUT {type=0,data=new UNION {mouse=new MOUSEINPUT {flags=4}}}}); }
    public static void Wheel(int x,int y,int delta) { if(!SetCursorPos(x,y))throw new InvalidOperationException("SetCursorPos failed"); Send(new[]{new INPUT {type=0,data=new UNION {mouse=new MOUSEINPUT {data=unchecked((uint)delta),flags=0x0800}}}}); }
    public static void CloseManager(IntPtr h) { if(!SetForegroundWindow(h))throw new InvalidOperationException("Cannot focus manager"); Send(new[]{Key(0x12,false),Key(0x73,false),Key(0x73,true),Key(0x12,true)}); }
  }
}
'@
    $desktopError=[MischiefQa.Desktop]::InputDesktopError()
    $session=(Get-Process -Id $PID).SessionId
    $gui=[Environment]::UserInteractive -and $session -ne 0 -and $desktopError -eq 0
    if ($gui) { Set-Check 'interactive_desktop' 'PASS' 'Interactive input desktop accessible' ([ordered]@{session_id=$session; input_desktop_win32_error=$desktopError; user_interactive=$true}) }
    else {
        $reason="UNAVAILABLE: user_interactive=$([Environment]::UserInteractive), session_id=$session, OpenInputDesktop Win32 error=$desktopError"
        Set-Check 'interactive_desktop' 'UNAVAILABLE' $reason
        foreach ($name in @('pet_window_screenshot','hide_shortcut','manager_ui','plus_activation_ui','clean_quit')) { Set-Check $name 'UNAVAILABLE' $reason }
    }
    $networkReady=Check 'network_capture' {
        $script:auditBackup=Join-Path $work 'audit-policy.csv'
        Command 'auditpol.exe' @('/backup',"/file:$auditBackup") | Out-Null
        $script:auditEnabled=$true
        Command 'auditpol.exe' @('/set','/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}','/success:enable') | Out-Null
        $probeStart=Get-Date
        Invoke-WebRequest -Uri 'https://api.github.com/rate_limit' -Headers @{'User-Agent'='MischiefPet-Store-QA'} | Out-Null
        Wait-For {
            @(Get-WinEvent -FilterHashtable @{LogName='Security';Id=5156;StartTime=$probeStart} -ErrorAction SilentlyContinue | Where-Object {
                [xml]$event=$_.ToXml(); $fields=@{}; foreach($d in $event.Event.EventData.Data){$fields[$d.Name]=$d.'#text'}
                $fields['Application'] -like '*\pwsh.exe' -and $fields['DestPort'] -eq '443'
            }).Count -gt 0
        } 15
        $script:networkStart=Get-Date
        [ordered]@{method='Windows Security event 5156, Filtering Platform Connection success audit'; positive_control='Real runner PowerShell HTTPS request to api.github.com recorded before application launch'; capture_started_at=$networkStart.ToUniversalTime().ToString('o'); application_unmodified=$true}
    }
    if (-not $networkReady) { throw 'Network observation prerequisite failed' }
    $launched=Check 'shell_launch' {
        $target='shell:AppsFolder\'+$package.PackageFamilyName+'!MischiefPet'
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $target | Out-Null
        Wait-For { @(Get-OwnedProcesses | Where-Object { $_.ExecutablePath -ieq (Join-Path $installRoot 'app\MischiefPet.exe') }).Count -gt 0 } 45
        [ordered]@{ method='explorer.exe shell:AppsFolder'; target=$target; processes=(Process-Receipt); bypass=$false }
    }
    if ($launched) {
        Check 'process_paths' {
            $rows=@(Process-Receipt); Assert-True ($rows.Count -gt 0) 'Installed process tree absent'
            $bad=@(Get-OwnedProcesses | Where-Object { -not $_.ExecutablePath -or -not $_.ExecutablePath.StartsWith($installRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) })
            Assert-True ($bad.Count -eq 0) 'Observed process tree includes unknown or non-package executable path'
            $rows
        } | Out-Null
        if ($gui) {
            $petReady=Check 'pet_window_screenshot' {
                Wait-For { @(App-Windows | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Width -lt 700 -and $_.Height -gt 0 -and $_.Height -lt 650 -and $_.Title -notlike 'Mischief Pet —*' }).Count -gt 0 } 30
                $pet=@(App-Windows | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Width -lt 700 -and $_.Height -gt 0 -and $_.Height -lt 650 -and $_.Title -notlike 'Mischief Pet —*' })
                $script:petHandles=@($pet | ForEach-Object Handle)
                [ordered]@{ windows=(Window-Receipt $pet); screenshot=(Screenshot '01-desktop-pet') }
            }
            if ($petReady) {
                Check 'hide_shortcut' {
                    $before=@(App-Windows | Where-Object { $petHandles -contains $_.Handle }); Assert-True (@($before | Where-Object Visible).Count -gt 0) 'Pet was not visible before shortcut'
                    [MischiefQa.Desktop]::HideShortcut()
                    Wait-For { @(App-Windows | Where-Object { $petHandles -contains $_.Handle -and $_.Visible }).Count -eq 0 } 10
                    $after=@(App-Windows | Where-Object { $petHandles -contains $_.Handle })
                    [ordered]@{ method='Win32 SendInput Ctrl+Shift+H'; before=(Window-Receipt $before); after=(Window-Receipt $after); screenshot=(Screenshot '02-desktop-hidden') }
                } | Out-Null
            }
            $managerOK=Check 'manager_ui' {
                # The accepted app's second-instance handler opens its existing manager.
                # Repeat actual shell activation instead of relying on tray overflow geometry.
                $target='shell:AppsFolder\'+$package.PackageFamilyName+'!MischiefPet'
                Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $target | Out-Null
                Wait-For { @(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' }).Count -eq 1 } 30
                $manager=@(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' })[0]
                $script:managerHandle=$manager.Handle
                Wait-For { $null -ne (Find-UI $managerHandle '^(Next · startup preferences|다음 · 시작 설정)$') } 30
                $welcomeOK=Check 'welcome_complete' {
                    Assert-True ($null -eq (Find-UI $managerHandle 'Plus US\$4\.99' -IncludeOffscreen)) 'Welcome exposes purchase price in Store edition'
                    Click-Element (Find-UI $managerHandle '^(Next · startup preferences|다음 · 시작 설정)$')
                    $startupYes=Reveal-UI $managerHandle '^(Start with my computer|같이 시작하기)$'
                    $startupNo=Reveal-UI $managerHandle '^(Not now|나중에)$'
                    Assert-True ($null -ne $startupYes -and $null -ne $startupNo -and -not $startupYes.Current.IsEnabled -and -not $startupNo.Current.IsEnabled) 'Store welcome startup choices must be read-only'
                    Click-Element (Reveal-UI $managerHandle '^(Next · privacy choice|다음 · 통계 선택)$')
                    Click-Element (Reveal-UI $managerHandle '^(No thanks|괜찮아요, 보내지 않을게요)$')
                    Click-Element (Reveal-UI $managerHandle '^(Start together|Save preferences|함께 시작하기|설정 저장하기)$')
                    $prefsFile=Join-Path $packageData 'LocalCache\Roaming\neogenesis-mischief-pet\preferences-v1.json'
                    Wait-For { (Test-Path $prefsFile) -and (Get-Content $prefsFile -Raw | ConvertFrom-Json).onboardingVersion -eq '0.6.0' } 15
                    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $target | Out-Null
                    Wait-For { @(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' }).Count -eq 1 } 30
                    $script:managerHandle=@(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' })[0].Handle
                    Assert-True ($null -eq (Find-UI $managerHandle '^(Next · startup preferences|다음 · 시작 설정)$')) 'Completed welcome reopened'
                    [ordered]@{onboarding_version='0.6.0'; explicit_privacy_decline=$true; welcome_purchase_price_absent=$true; startup_choices_read_only=$true; repeated_shell_activation_does_not_reopen_welcome=$true}
                }
                Assert-True $welcomeOK 'Fresh welcome completion failed'
                [ordered]@{ method='Second shell AppsFolder activation; accepted second-instance handler opens manager'; window=(Window-Receipt @($manager)); screenshot=(Screenshot '03-manager') }
            }
            if ($managerOK) {
                Check 'plus_activation_ui' {
                    Wait-For { $null -ne (Find-UI $managerHandle '^Plus$') } 30
                    Click-Element (Find-UI $managerHandle '^Plus$')
                    Check 'store_purchase_ui' {
                        Assert-True ($null -eq (Find-UI $managerHandle '^(Get Plus · one-time purchase|Plus 구매 · 일회 결제)$' -IncludeOffscreen)) 'Purchase button appears in Store accessibility tree'
                        Assert-True ($null -eq (Find-UI $managerHandle 'Plus US\$4\.99' -IncludeOffscreen)) 'Purchase price appears in Store accessibility tree'
                        $key=Reveal-UI $managerHandle '^(License key|라이선스 키)$' -Password
                        Assert-True ($null -ne $key -and $key.Current.IsEnabled) 'License-key entry missing or disabled'
                        [ordered]@{purchase_button_absent=$true; purchase_price_absent=$true; license_entry_present_and_enabled=$true; method='Real installed UI Automation tree, including offscreen elements'}
                    } | Out-Null
                    $key=Reveal-UI $managerHandle '^(License key|라이선스 키)$' -Password
                    Assert-True ($null -ne $key) 'Real Plus license password input not exposed by UI Automation'
                    $activate=Reveal-UI $managerHandle '^(Activate|활성화)$'
                    Assert-True ($null -ne $activate) 'Real Plus activation button not exposed by UI Automation'
                    Click-Element $activate
                    $message=Reveal-UI $managerHandle '^(Enter your license key\.|라이선스 키를 입력해 주세요\.)$' -Seconds 10
                    Assert-True ($null -ne $message) 'Empty-input validation message was not observed'
                    [ordered]@{ method='Real UI Automation discovery + SendInput clicks and mouse-wheel scrolling'; license_entered=$false; activation_network_requested=$false; empty_input_validation_observed=$true; screenshot=(Screenshot '04-plus-activation-empty') }
                } | Out-Null
            }
            if ($managerOK) {
                Check 'store_startup_state' {
                    Click-Element (Reveal-UI $managerHandle '^(Settings|설정)$')
                    $null=Reveal-UI $managerHandle '^Start with my computer|^컴퓨터를 켤 때 함께 시작'
                    $indicator=Find-Checkbox $managerHandle '^Start with my computer|^컴퓨터를 켤 때 함께 시작'
                    Assert-True ($null -ne $indicator -and -not $indicator.Current.IsEnabled) 'Store startup indicator is not read-only'
                    $toggle=$indicator.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
                    Assert-True ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Startup indicator is not off'
                    $note=Reveal-UI $managerHandle '^For the Microsoft Store edition, enable or disable this in Windows Startup apps\.|^Microsoft Store 버전은 Windows 시작 앱 설정에서'
                    Assert-True ($null -ne $note) 'Real OS-state explanation absent'
                    $startupKey='HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\'+$package.PackageFamilyName+'\MischiefPetStartupTask'
                    $startupState=if(Test-Path $startupKey){(Get-ItemProperty $startupKey -Name State -ErrorAction Stop).State}else{0}
                    Assert-True ($startupState -in @(0,1,3)) "OS startup state unexpectedly enabled: $startupState"
                    $updateNote=Reveal-UI $managerHandle '^(Microsoft Store manages updates for this edition\.|이 버전의 업데이트는 Microsoft Store에서 관리해요\.)$'
                    Assert-True ($null -ne $updateNote) 'Store-managed update explanation absent'
                    [ordered]@{task_id='MischiefPetStartupTask'; registry_state=$startupState; registry_key_present=(Test-Path $startupKey); indicator_enabled=$false; indicator_toggle='Off'; os_managed_explanation_present=$true; updates_store_managed=$true; screenshot=(Screenshot '05-store-startup-state')}
                } | Out-Null
            }
        }
        Check 'packaged_appdata' {
            $directory=Join-Path $packageData 'LocalCache\Roaming\neogenesis-mischief-pet'
            $save=Join-Path $directory 'pet-v1.json'
            Wait-For { (Test-Path -LiteralPath $save -PathType Leaf) -or (Test-Path -LiteralPath $plainSave) } 20
            Assert-True (-not (Test-Path -LiteralPath $plainSave)) 'Unvirtualized appdata created: packaged isolation FAILED'
            $saves=@(Get-ChildItem -LiteralPath $packageData -Filter pet-v1.json -File -Recurse -ErrorAction SilentlyContinue)
            Assert-True ($saves.Count -eq 1 -and $saves[0].FullName -eq $save) 'Expected exactly one actual package-scoped pet save'
            [ordered]@{ actual_appdata_directory=(Protect-Text $directory); package_data_root=(Protect-Text $packageData); localcache_roaming_expected=(Protect-Text $directory); unvirtualized_path_absent=$true; files=(Save-Inventory $directory); contents_recorded=$false }
        } | Out-Null
        if ($gui -and $managerHandle -ne [IntPtr]::Zero) {
            Check 'close_to_tray' {
                $before=Process-Receipt
                [MischiefQa.Desktop]::CloseManager($managerHandle)
                Wait-For { @(App-Windows | Where-Object { $_.Handle -eq $managerHandle -and $_.Visible }).Count -eq 0 } 15
                Start-Sleep -Seconds 3
                Assert-True (@(Get-OwnedProcesses).Count -gt 0) 'Closing manager exited the companion instead of keeping tray alive'
                $after=Process-Receipt
                $target='shell:AppsFolder\'+$package.PackageFamilyName+'!MischiefPet'
                Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $target | Out-Null
                Wait-For { @(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' }).Count -eq 1 } 30
                $script:managerHandle=@(App-Windows | Where-Object { $_.Visible -and $_.Title -like 'Mischief Pet —*' })[0].Handle
                [ordered]@{method='Real SendInput Alt+F4 on foreground manager'; before=$before; hidden_manager_processes_alive=$after; reopen_by_shell_activation=$true; screenshot=(Screenshot '06-manager-reopened')}
            } | Out-Null
            Check 'clean_quit' {
                $before=Process-Receipt; $started=[Diagnostics.Stopwatch]::StartNew()
                $quit=Reveal-UI $managerHandle '^(Quit Mischief Pet|Mischief Pet 종료)$'
                Assert-True ($null -ne $quit) 'Explicit Quit button not exposed by UI Automation'
                Click-Element $quit
                Wait-For { @(Get-OwnedProcesses).Count -eq 0 } 15
                $started.Stop()
                [ordered]@{ method='Real UI Automation discovery + SendInput click on explicit Quit Mischief Pet'; forced=$false; inspector=$false; elapsed_ms=$started.ElapsedMilliseconds; before=$before; after=(Process-Receipt); entire_observed_process_tree_gone=$true }
            } | Out-Null
        }
    }
    Check 'no_update_request' {
        Assert-True ($auditEnabled -and $null -ne $networkStart) 'Network audit was not enabled before shell launch'
        $connections=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=5156;StartTime=$networkStart} -ErrorAction SilentlyContinue | ForEach-Object {
            [xml]$event=$_.ToXml(); $fields=@{}; foreach($d in $event.Event.EventData.Data){$fields[$d.Name]=$d.'#text'}
            if($fields['Application'] -like '*\MischiefPet.exe' -and $fields['DestPort'] -in @('80','443')) {
                [ordered]@{process_id=$fields['ProcessID']; application=$fields['Application']; destination_address=$fields['DestAddress']; destination_port=$fields['DestPort']; timestamp=$_.TimeCreated.ToUniversalTime().ToString('o')}
            }
        })
        Assert-True ($connections.Count -eq 0) 'Installed companion made an HTTP/HTTPS connection during Store launch/welcome/UI/close/Quit'
        [ordered]@{method='Windows Security 5156 OS network audit; independent positive control passed'; observation='Entire installed application session before WACK'; http_https_connections=$connections; update_requests=0; application_injection=$false}
    } | Out-Null
    # Force-stop is cleanup, never a substitute clean-quit PASS. WACK starts from an idle package.
    Check 'cleanup_processes' {
        $before=Process-Receipt
        foreach ($p in @(Get-OwnedProcesses)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
        Wait-For { @(Get-OwnedProcesses).Count -eq 0 } 15
        [ordered]@{ forced_owned_processes=$before; remaining=(Process-Receipt) }
    } | Out-Null
    $wack=Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10') -Filter appcert.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wack) { Set-Check 'wack' 'UNAVAILABLE' 'UNAVAILABLE: appcert.exe not installed under Windows Kits\10 on this hosted runner' }
    elseif (-not $gui) { Set-Check 'wack' 'UNAVAILABLE' 'UNAVAILABLE: appcert.exe present, but runner has no accessible interactive input desktop; no substitute WACK execution' ([ordered]@{ executable=$wack.FullName }) }
    else {
        Check 'wack' {
            $report=Join-Path $EvidenceDirectory 'wack-report.xml'
            $stdout=Join-Path $work 'wack-stdout.txt'; $stderr=Join-Path $work 'wack-stderr.txt'
            $started=[DateTime]::UtcNow.ToString('o')
            $p=Start-Process -FilePath $wack.FullName -ArgumentList @('test','-appxpackagepath',('"'+$signedFile+'"'),'-reportoutputpath',('"'+$report+'"')) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            try { if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force; throw 'Actual WACK exceeded 15-minute deadline' }; $p.Refresh() }
            finally {
                $receipt.commands += [ordered]@{ executable=$wack.FullName; arguments=@('test','-appxpackagepath',(Protect-Text $signedFile),'-reportoutputpath','wack-report.xml'); started_at=$started; exit_code=$p.ExitCode; stdout=(Protect-Text (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)); stderr=(Protect-Text (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)) }
                if (Test-Path -LiteralPath $report) { $text=Protect-Text (Get-Content -LiteralPath $report -Raw); [IO.File]::WriteAllText($report,$text,[Text.UTF8Encoding]::new($false)) }
            }
            Assert-True (Test-Path -LiteralPath $report) 'Actual WACK produced no report'
            $receipt.provenance.wack=[ordered]@{ executable=$wack.FullName; exit_code=$p.ExitCode; report='wack-report.xml'; report_sha256=(Get-FileHash $report -Algorithm SHA256).Hash.ToLowerInvariant(); report_redacted_runner_paths=$true }
            Assert-True ($p.ExitCode -eq 0) "Actual WACK failed with exit $($p.ExitCode); retained report is authoritative"
            [xml]$xml=Get-Content -LiteralPath $report -Raw
            $overall=$xml.DocumentElement.GetAttribute('OVERALL_RESULT')
            Assert-True ($overall -eq 'PASS') 'WACK report does not explicitly declare OVERALL_RESULT PASS'
            $receipt.provenance.wack
        } | Out-Null
    }
    Check 'uninstall' {
        foreach ($p in @(Get-OwnedProcesses)) { Stop-Process -Id $p.ProcessId -Force }
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
        Assert-True (@(Get-AppxPackage -Name $identity).Count -eq 0) 'Package remains registered after uninstall'
        Wait-For { -not (Test-Path -LiteralPath $packageData) } 30
        Assert-True (@(Get-OwnedProcesses).Count -eq 0) 'Installed process tree remains after uninstall'
        [ordered]@{ removed_full_name=$package.PackageFullName; absent=$true; package_data_removed_by_uninstall=$true; processes_absent=$true }
    } | Out-Null
} catch {
    $receipt.fatal_error=Protect-Text $_.Exception.Message
} finally {
    if ($safeRunner) {
        Check 'cleanup_processes' {
            $before=Process-Receipt
            foreach ($p in @(Get-OwnedProcesses)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
            Wait-For { @(Get-OwnedProcesses).Count -eq 0 } 15
            [ordered]@{ forced_owned_processes=$before; remaining=(Process-Receipt); clean_quit_status=$checks.clean_quit.status }
        } | Out-Null
        Check 'cleanup_package' {
            if ($packageOwned) { foreach ($p in @(Get-AppxPackage -Name $identity)) { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop } }
            Assert-True (@(Get-AppxPackage -Name $identity).Count -eq 0) 'Owned test package remains registered'
            [ordered]@{ absent=$true; owned_registration_attempted=$packageOwned }
        } | Out-Null
        Check 'cleanup_certificates' {
            if ($certThumb) {
                # -DeleteKey removes the runner-only private key container as well as its certificate.
                $privatePath='Cert:\CurrentUser\My\'+$certThumb
                $publicPath='Cert:\LocalMachine\TrustedPeople\'+$certThumb
                if (Test-Path $publicPath) { Remove-Item -LiteralPath $publicPath -Force }
                if (Test-Path $privatePath) { Remove-Item -LiteralPath $privatePath -DeleteKey -Force }
                Assert-True (-not (Test-Path $publicPath) -and -not (Test-Path $privatePath)) 'Owned signing/trust certificate remains'
            }
            [ordered]@{ certificate_thumbprint=$certThumb; private_certificate_and_key_removed=$true; trust_certificate_removed=$true; private_key_ever_exported=$false }
        } | Out-Null
        Check 'cleanup_files' {
            if ($auditEnabled -and $auditBackup -and (Test-Path $auditBackup)) { Command 'auditpol.exe' @('/restore',"/file:$auditBackup") | Out-Null }
            if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
            if ($packageData -and (Test-Path -LiteralPath $packageData) -and $checks.cleanup_package.status -eq 'PASS') { Remove-Item -LiteralPath $packageData -Recurse -Force }
            # Preflight proved this path absent; if virtualization failed only this newly owned path may be removed.
            $outsideCreated=Test-Path -LiteralPath $plainSave
            if ($outsideCreated) { Remove-Item -LiteralPath $plainSave -Recurse -Force }
            Assert-True (-not $outsideCreated) 'Unvirtualized appdata was created outside package virtualization'
            Assert-True (-not $work -or -not (Test-Path -LiteralPath $work)) 'Runner package/certificate working files remain'
            Assert-True (-not $packageData -or -not (Test-Path -LiteralPath $packageData)) 'Owned package appdata remains'
            [ordered]@{ working_files_absent=$true; package_data_absent=$true; unexpected_unvirtualized_data_created=$outsideCreated; unvirtualized_data_absent=$true }
        } | Out-Null
    }
    $statuses=@($checks.Values | ForEach-Object status)
    if ($statuses -contains 'FAIL') { $receipt.result='FAIL' }
    elseif ($statuses -contains 'NOTEXERCISED' -or $statuses -contains 'UNAVAILABLE') { $receipt.result='INCOMPLETE' }
    else { $receipt.result='PASS' }
    $receipt.finished_at=[DateTime]::UtcNow.ToString('o')
    # Workflow creates this directory before invocation, including for preflight failures.
    if (Test-Path -LiteralPath $EvidenceDirectory) {
        [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'result.json'),(Protect-Text ($receipt | ConvertTo-Json -Depth 30)),[Text.UTF8Encoding]::new($false))
    }
    Write-Output (Protect-Text ($receipt | ConvertTo-Json -Depth 30))
}
if ($receipt.result -ne 'PASS') { exit 1 }
