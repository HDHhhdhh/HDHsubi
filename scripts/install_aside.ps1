# Official Windows CLI procedure: https://docs.aside.com/help/developers
$ErrorActionPreference = 'Stop'
$installerPath = Join-Path ([IO.Path]::GetTempPath()) ('hdhsubi-aside-' + [guid]::NewGuid().ToString('N') + '.ps1')
$publisher = 'CN=AT YOUR SIDE INC, O=AT YOUR SIDE INC, L=San Francisco, S=California, C=US'
try {
  Invoke-WebRequest -UseBasicParsing -Uri 'https://releases.aside.com/install.ps1' -OutFile $installerPath
  $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
  if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -ne $publisher -or $null -eq $signature.TimeStamperCertificate) {
    throw "Aside CLI installer signature verification failed: $($signature.Status). Do not bypass this check."
  }
  & $installerPath
} finally {
  if (Test-Path -LiteralPath $installerPath -PathType Leaf) { Remove-Item -LiteralPath $installerPath -Force }
}
