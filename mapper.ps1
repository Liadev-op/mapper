#requires -version 5.1
# Liadev - RedDriveMapper bootstrap PS1
# Ejecuta mapeos leyendo drives.json desde Internet con cache y fallback.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- Config remota con cache ----------
$ConfigUrls = @(
  'https://cdn.jsdelivr.net/gh/Liadev-op/mapper@main/drives.json',
  'https://raw.githubusercontent.com/Liadev-op/mapper/refs/heads/main/drives.json'
)

$CacheDir  = Join-Path $env:ProgramData 'Liadev\RedDriveMapper\cache'
$CacheFile = Join-Path $CacheDir 'drives.json'
$MetaFile  = Join-Path $CacheDir 'drives.json.meta'

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)] [scriptblock] $Script,
    [int] $MaxRetries = 3
  )
  $delay = 400
  for($i=1; $i -le $MaxRetries; $i++){
    try { return & $Script }
    catch {
      if($i -eq $MaxRetries){ throw }
      Start-Sleep -Milliseconds ($delay + (Get-Random -Min 0 -Max 400))
      $delay = [Math]::Min($delay * 2, 5000)
    }
  }
}

function Get-Meta {
  if(Test-Path $MetaFile){
    try { return Get-Content $MetaFile -Raw | ConvertFrom-Json } catch { }
  }
  [pscustomobject]@{ Url = $null; ETag = $null; LastSuccessUtc = '2000-01-01T00:00:00Z' }
}

function Save-Meta($m){
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  $m | ConvertTo-Json -Depth 5 | Set-Content -Path $MetaFile -Encoding UTF8
}

function Get-RemoteConfig {
  param([TimeSpan]$MaxCacheAge = ([TimeSpan]::FromMinutes(60)))
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  $meta = Get-Meta

  # Si cache es reciente, úsalo
  $last = Get-Date $meta.LastSuccessUtc
  if((Test-Path $CacheFile) -and ((Get-Date) - $last -lt $MaxCacheAge)){
    try { return Get-Content $CacheFile -Raw } catch { }
  }

  # Jitter para evitar estampida
  Start-Sleep -Milliseconds (Get-Random -Min 150 -Max 1200)

  foreach($url in $ConfigUrls){
    try {
      $headers = @{}
      if($meta.ETag -and $meta.Url -and ($meta.Url -eq $url)){ $headers['If-None-Match'] = $meta.ETag }

      $resp = Invoke-WithRetry -Script {
        Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing
      }

      if($resp.StatusCode -eq 304){
        # Not Modified -> usa cache
        $meta.LastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-Meta $meta
        if(Test-Path $CacheFile){ return Get-Content $CacheFile -Raw }
        continue
      }

      if($resp.StatusCode -eq 429){
        Write-Host "429 Too Many Requests desde $url"
        continue
      }

      if(-not $resp.Content){ throw "Respuesta vacía desde $url" }

      # Guarda cache y meta
      $resp.Content | Set-Content -Path $CacheFile -Encoding UTF8
      $meta.Url = $url
      $meta.ETag = $resp.Headers['ETag']
      $meta.LastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o')
      Save-Meta $meta

      return $resp.Content
    }
    catch {
      Write-Host "Fallo descargando $url: $($_.Exception.Message)"
    }
  }

  # Fallback a cache viejo si existe
  if(Test-Path $CacheFile){ return Get-Content $CacheFile -Raw }
  throw "No se pudo obtener drives.json y no hay cache local."
}

# ---------- Utilidades de red ----------
function Disconnect-Letter([string]$letter){
  & net.exe use $letter /delete /y | Out-Null
}

function Disconnect-ServerSessions([string]$server){
  if([string]::IsNullOrWhiteSpace($server)){ return }
  # Corta sesiones activas hacia el servidor
  & net.exe use "\\$server\*" /delete /y | Out-Null
}

function Extract-Server([string]$unc){
  if(-not $unc.StartsWith('\\')){ return $null }
  $resto = $unc.TrimStart('\')
  $idx = $resto.IndexOf('\')
  if($idx -gt 0){ return $resto.Substring(0, $idx) }
  return $null
}

function Extract-Share([string]$unc){
  if(-not $unc.StartsWith('\\')){ return $null }
  $resto = $unc.TrimStart('\')
  $parts = $resto.Split('\')
  if($parts.Count -ge 2){ return $parts[1] }
  return $null
}

function Set-DriveLabel([string]$letter,[string]$server,[string]$share,[string]$label){
  try {
    # Etiqueta vía Registro (Explorer MountPoints2). Opcional: dejá como no-op si no te interesa.
    # Placeholder: implementar si necesitás exactamente tu método de etiquetado.
    return
  } catch {}
}

function Save-CredentialIfNeeded([string]$server,[string]$user,[string]$pass){
  if([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)){ return }
  # Guarda para SMB y también entrada genérica
  & cmdkey.exe /generic:$server /user:$user /pass:$pass | Out-Null
}

function Map-One {
  param(
    [Parameter(Mandatory)][string]$Letter,
    [Parameter(Mandatory)][string]$Path,
    [string]$User,
    [string]$Password,
    [string]$Label,
    [bool]$Persist = $true,
    [bool]$SaveCreds = $false
  )

  $letter = if($Letter.EndsWith(':')){ $Letter } else { "$Letter:" }
  $server = Extract-Server $Path

  # limpia previos
  Disconnect-Letter $letter
  if($server){ Disconnect-ServerSessions $server }

  # arma comando net use
  $persistFlag = if($Persist){ '/persistent:yes' } else { '/persistent:no' }
  if([string]::IsNullOrWhiteSpace($User)){
    $args = @('use', $letter, $Path, $persistFlag)
  } else {
    $args = @('use', $letter, $Path, $Password, "/user:$User", $persistFlag)
  }

  $p = Start-Process -FilePath net.exe -ArgumentList $args -NoNewWindow -PassThru -Wait -RedirectStandardOutput "$env:TEMP\netuse.out" -RedirectStandardError "$env:TEMP\netuse.err"
  if($p.ExitCode -ne 0){
    $err = Get-Content "$env:TEMP\netuse.err" -Raw
    throw "Error mapeando $letter -> $Path. Código $($p.ExitCode). $err"
  }

  # etiqueta opcional
  $share = Extract-Share $Path
  if($Label -and $server -and $share){
    Set-DriveLabel -letter $letter -server $server -share $share -label $Label
  }

  if($SaveCreds -and $User -and $Password -and $server){
    Save-CredentialIfNeeded -server $server -user $User -pass $Password
  }

  Write-Host "[$letter] mapeada -> $Path"
}

# ---------- Flujo principal ----------
try {
  $json = Get-RemoteConfig
  $cfg  = $json | ConvertFrom-Json

  if(-not $cfg -or -not $cfg.drives){
    throw "Config sin 'drives'."
  }

  foreach($d in $cfg.drives){
    $letter = $d.letter
    $path   = $d.path
    if([string]::IsNullOrWhiteSpace($letter) -or [string]::IsNullOrWhiteSpace($path)){
      Write-Host "Entrada inválida, se omite."
      continue
    }

    # Resolución de credenciales: JSON -> CredMan (opcional) -> Prompt
    $user = $d.username
    $pass = $d.password

    if(-not $user -and -not $pass -and $d.promptIfMissing){
      $cred = Get-Credential -Message "Credenciales para $path"
      $user = $cred.UserName
      $pass = $cred.GetNetworkCredential().Password
    }

    Map-One -Letter $letter -Path $path -User $user -Password $pass -Label $d.label -Persist ($d.persist -ne $false) -SaveCreds ($d.saveCreds -eq $true)
  }

  Write-Host "Listo. Todas las unidades procesadas."
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)"
  exit 1
}
