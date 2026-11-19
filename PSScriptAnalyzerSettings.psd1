@{
    # Deliberate style exceptions for SysOrg (P3-3):
    #   - the console UI is Write-Host by design (color-coded preview-first console app)
    #   - plural noun rule misfires on Get-SysOrgDuplicates / New-SysOrgAppFolders
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
    )
    Severity = @('Error')
}
