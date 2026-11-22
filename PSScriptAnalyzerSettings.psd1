@{
    # Deliberate style exceptions for SysOrg (P3-3):
    #   - the console UI is Write-Host by design (color-coded preview-first console app)
    #   - plural noun rule misfires on Get-SysOrgDuplicates / New-SysOrgAppFolders
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
    )
    # v2.1.1: Warnings are reported too (CI prints them but only Errors fail the build).
    Severity = @('Error','Warning')
}
