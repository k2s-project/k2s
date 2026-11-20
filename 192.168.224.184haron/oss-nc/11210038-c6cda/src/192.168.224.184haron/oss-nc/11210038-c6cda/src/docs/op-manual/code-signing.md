<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# K2s Code Signing

This document describes the K2s code signing functionality that ensures all executables and PowerShell scripts are signed with a trusted certificate.

## Overview

K2s includes comprehensive code signing capabilities to meet enterprise security requirements:

- **PowerShell Scripts**: All `.ps1`, `.psm1` files are signed with Authenticode signatures
- **Executables**: All `.exe`, `.dll` files are signed with code signing certificates
- **Installer Packages**: All `.msi` files are signed with code signing certificates
- **Automated Packaging**: Create complete signed packages via `k2s system package`
- **CI/CD Integration**: Automated signing in GitHub Actions workflows

**Note**: CMD and BAT files cannot be Authenticode signed as they are plain text files and are excluded from the signing process.

**Important**: Certificate operations require administrator privileges as certificates are stored in the LocalMachine certificate store for enterprise-wide deployment.

## Quick Start

### Create a Signed Package

```powershell
# Create package with existing certificate
k2s system package --target-dir "C:\tmp" --name "k2s-signed.zip" --certificate "mycert.pfx" --password "mycertpassword"

# Create package for offline installation with code signing
k2s system package --target-dir "C:\tmp" --name "k2s-offline-signed.zip" --for-offline-installation --certificate "mycert.pfx" --password "mycertpassword"
```

### Install Certificate for Trust

```powershell
# Import certificate from package using standard PowerShell cmdlets (requires administrator privileges)
Import-PfxCertificate -FilePath k2s-signing.pfx -CertStoreLocation Cert:\LocalMachine\My
Import-Certificate -FilePath k2s-signing.pfx -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

### Create Self-Signed Certificate for Testing

For development and testing purposes, you can create a self-signed code signing certificate. **Important**: Self-signed certificates must be installed to the Trusted Root store to avoid trust warnings.

```powershell
# Create a self-signed code signing certificate (requires administrator privileges)
$cert = New-SelfSignedCertificate -Subject "CN=K2s Test Code Signing" `
    -Type CodeSigningCert `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(5) `
    -CertStoreLocation Cert:\LocalMachine\My `
    -KeyExportPolicy Exportable

# Export to PFX file with password
$password = ConvertTo-SecureString "TestPassword123" -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath "k2s-test-signing.pfx" -Password $password

# Export the public certificate for trust installation
Export-Certificate -Cert $cert -FilePath "k2s-test-signing.cer"

# Install to Trusted Root Certification Authorities (makes the certificate trusted)
Import-Certificate -FilePath "k2s-test-signing.cer" -CertStoreLocation Cert:\LocalMachine\Root

# Install to TrustedPublisher store for PowerShell script execution
Import-Certificate -FilePath "k2s-test-signing.cer" -CertStoreLocation Cert:\LocalMachine\TrustedPublisher

# Test the certificate with K2s package creation
k2s system package --target-dir "C:\tmp" --name "k2s-test-signed.zip" --certificate "k2s-test-signing.pfx" --password "TestPassword123"
```

**Why install to Trusted Root?**
Self-signed certificates are not trusted by default. Installing the certificate to `Cert:\LocalMachine\Root` makes Windows trust the certificate, preventing "certificate chain terminated in a root certificate which is not trusted" errors during code signing verification.

## Command Reference

### `k2s system package`

Creates a complete K2s package with all components signed.

**Required Options:**

- `--target-dir, -d`: Target directory for the package
- `--name, -n`: The name of the zip package (must have .zip extension)

**Code Signing Options:**

- `--certificate, -c`: Path to code signing certificate (.pfx file)
- `--password, -w`: Password for the certificate file

**Additional Options:**

- `--for-offline-installation`: Creates a package for offline installation
- `--proxy, -p`: HTTP proxy if available
- `--master-cpus`: Number of CPUs allocated to master VM
- `--master-memory`: Amount of RAM to allocate to master VM (minimum 2GB)
- `--master-disk`: Disk size allocated to the master VM (minimum 10GB)
- `--k8s-bins`: Path to directory of locally built Kubernetes binaries

**Examples:**

```bash
# Basic package creation
k2s system package --target-dir "C:\tmp" --name "k2s-package.zip"

# Package for offline installation
k2s system package --target-dir "C:\tmp" --name "k2s-offline.zip" --for-offline-installation

# Signed package with existing certificate
k2s system package --target-dir "C:\tmp" --name "k2s-signed.zip" --certificate "./certs/my-cert.pfx" --password "certpassword"

# Signed offline package with all options
k2s system package --target-dir "C:\tmp" --name "k2s-complete.zip" --for-offline-installation --certificate "./certs/my-cert.pfx" --password "certpassword" --proxy "http://proxy:8080"
```

**Note**: When using code signing, both `--certificate` and `--password` must be provided together.

## PowerShell Module Reference

The `k2s.signing.module` provides low-level signing functionality. **Note**: All certificate operations require administrator privileges.

### Certificate Management

```powershell
# List K2s certificates (requires administrator privileges) - Use standard PowerShell cmdlets
Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*K2s*" }
```

### Signing Operations

```powershell
# Sign all files (executables and scripts) in directory using certificate file
Set-K2sFileSignature -SourcePath "C:\k2s" -CertificatePath "cert.pfx" -Password $securePassword
```

## Certificate Requirements

### Self-Signed Certificates

The built-in certificate creation uses:

- **Algorithm**: RSA 2048-bit
- **Key Usage**: Digital Signature
- **Validity**: 10 years (configurable)
- **Type**: Code Signing Certificate

### External Certificates

For production use, you can provide:

- **Commercial certificates** from trusted CAs (Digicert, GlobalSign, etc.)
- **Enterprise certificates** from internal CAs
- **Hardware Security Module (HSM)** certificates

Requirements:

- Must support code signing (`Enhanced Key Usage: 1.3.6.1.5.5.7.3.3`)
- Must be in PKCS#12 (.pfx) format with private key
- Must be password-protected

## Security Considerations

### Certificate Storage

- **Development**: Self-signed certificates stored in `LocalMachine\My` (requires administrator privileges)
- **Production**: Use HSM or secure certificate storage
- **CI/CD**: Certificates stored as encrypted secrets

### Trust Validation

The signing process installs certificates in:

- `LocalMachine\My`: For signing operations
- `LocalMachine\TrustedPublisher`: For script execution
- `LocalMachine\Root`: For trust chain validation

### Execution Policy

Signed scripts work with these PowerShell execution policies:

- `RemoteSigned`: Allows locally created and signed scripts
- `AllSigned`: Requires all scripts to be signed
- `Restricted`: Blocks all script execution

## CI/CD Integration

### GitHub Actions

The included workflow (`.github/workflows/code-signing.yml`) provides:

- **Automatic signing** on commits to main/develop
- **Certificate management** via GitHub Secrets
- **Signed release packages** for tagged versions
- **Signature verification** in CI pipeline

### Setup GitHub Secrets

For automated signing, configure these secrets:

```
K2S_SIGNING_CERT_BASE64    # Base64-encoded .pfx certificate
K2S_SIGNING_CERT_PASSWORD  # Certificate password
```

### Manual Certificate Creation

To create certificates for CI/CD, use standard PowerShell cmdlets:

```powershell
# Create certificate using standard PowerShell
$cert = New-SelfSignedCertificate -Subject "CN=K2s Code Signing Certificate" `
    -Type CodeSigningCert `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(10) `
    -CertStoreLocation Cert:\LocalMachine\My

# Export to PFX file
$password = ConvertTo-SecureString "YourPassword" -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath "k2s-ci.pfx" -Password $password

# Convert to base64 for GitHub Secrets
$bytes = [System.IO.File]::ReadAllBytes("k2s-ci.pfx")
$base64 = [Convert]::ToBase64String($bytes)
Write-Output $base64
```

## Verification

### Verify PowerShell Scripts

```powershell
# Check script signature
$sig = Get-AuthenticodeSignature -FilePath "script.ps1"
Write-Host "Status: $($sig.Status)"
Write-Host "Signer: $($sig.SignerCertificate.Subject)"
```

### Verify Executables

```cmd
# Using signtool (Windows SDK required)
signtool verify /v /pa app.exe

# Check certificate details
signtool verify /v /pa /all app.exe
```

### Package Verification

Signed packages include a `package-manifest.json` with:

- Package creation timestamp
- Certificate information
- Count of signed files
- Verification checksums

## Troubleshooting

### Common Issues

**"Execution policy does not allow this script"**

- Solution: Install certificate using standard PowerShell cmdlets (`Import-PfxCertificate`, `Import-Certificate`)
- Alternative: Set execution policy to `RemoteSigned`

**"Certificate not found for signing"**

- Solution: Verify certificate is in `LocalMachine\My` store (requires administrator privileges)
- Check thumbprint matches signing command

**"Signtool not found"**

- Solution: Install Windows SDK or Visual Studio Build Tools
- Alternative: Use Windows ADK

### Debug Signing Issues

```powershell
# List available certificates (requires administrator privileges)
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.KeyUsage -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature }

# Test certificate
$cert = Get-ChildItem Cert:\LocalMachine\My\THUMBPRINT
Test-Certificate -Cert $cert -Policy SSL

# Validate script signature
$sig = Get-AuthenticodeSignature -FilePath "script.ps1"
$sig | Format-List *
```

## Best Practices

### Development

- Use self-signed certificates for local development
- Include certificate import in setup scripts
- Test with `AllSigned` execution policy

### Production

- Use commercial or enterprise CA certificates
- Implement certificate rotation procedures
- Monitor certificate expiration dates
- Use HSM for private key protection

### Distribution

- Include certificates in installation packages
- Document certificate import procedures
- Provide verification instructions
- Maintain certificate trust chains

## Related Documentation

- [PowerShell Execution Policies](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies)
- [Authenticode Signing](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-authenticodesignature)
- [Code Signing Best Practices](https://docs.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-best-practices)

## Development and Testing

### Unit Testing

The K2s signing module includes comprehensive unit tests that demonstrate best practices for testing PowerShell modules with external dependencies:

**Location**: `lib\modules\windows\common\k2s.signing.module\k2s.signing.module.unit.tests.ps1`

**Key Features**:

- **Zero Side Effects**: Tests use mocks and don't create certificates or modify system state
- **Fast Execution**: Complete test suite runs in ~1-2 seconds
- **Comprehensive Coverage**: Tests all signing functions and edge cases
- **Mock Strategy**: Uses module-level mocking with PSObject-based certificate mocks

**Running Tests**:

```powershell
# Run signing module unit tests
Invoke-Pester .\lib\modules\windows\common\k2s.signing.module\k2s.signing.module.unit.tests.ps1

# Run with detailed output
Invoke-Pester -Output Detailed .\lib\modules\windows\common\k2s.signing.module\k2s.signing.module.unit.tests.ps1
```

The unit tests serve as both validation and documentation of proper mocking techniques for external dependencies like certificate operations, file system access, and external tool execution.

For detailed information about PowerShell module unit testing best practices, see [Automated Testing with Pester](../dev-guide/contributing/automated-testing.md#automated-testing-with-pester).
