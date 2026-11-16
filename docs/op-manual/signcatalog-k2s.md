<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Signing of *K2s* artifacts 
## What use case to consider
Enterprises using Device Guard or Windows Defender Application Control (WDAC) or having an Installer Packages with Signed Components.

## Solution used
A .cat file (catalog file) can be used to sign multiple files collectively without signing each binary individually.
For the entire *k2s* distribution such an catalog file will be created always in sync with all the artifacts included (exe, ps1, ... files).
The catalog file is always located under:
```\build\catalog\k2s.cat```

## Sign the catalog file
To sign a catalog file (.cat) in Windows, you use the signtool.exe utility, which is included in the Windows SDK. 
Signing a catalog file is essential when complying with Windows Code Integrity Policies, or publishing via Windows Update. 

Best is to have an certificate from an official certificate issuer (also called Certificate Authorities (CAs)). 
These are trusted organizations that issue digital certificates for code signing.
Examples are: DigiCert, Sectigo, Globalsign, ...

In case that you don't have such an certificate from an official certificate issuer, you could also use an self-signed certificate:

```
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=K2sCatalogCertificate" -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(10)
```

After creating such an certificate, you can export it to a file:

```
Export-PfxCertificate -Cert $cert -FilePath "C:\Path\To\Your\Certificates\MyCatalogSigningCert.pfx" -Password $password
```

Also the public key can be export to a file:

```
Export-Certificate -Cert $cert -FilePath "C:\Path\To\Your\Certificates\MyCatalogSigningCert.cer"
```

At the end, either the certificate from an official certificate issuer or the self signed one can be used to sign the catalog file:

```
signtool.exe sign /f "C:\Path\To\Your\Certificates\MyCatalogSigningCert.pfx" /p "YourStrongPassword!" /fd SHA256 /v ".\build\catalog\k2s.cat"
```

Please don't forget to import the public key into the local store:

```
$CertificatePath = "C:\Path\To\Your\Certificates\MyCatalogSigningCert.cer"
Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

