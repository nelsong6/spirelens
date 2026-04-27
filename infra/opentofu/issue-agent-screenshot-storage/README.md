# Issue-Agent Screenshot Storage

This OpenTofu stack provisions public-read Azure Blob Storage for issue-agent screenshot previews.

It creates:

- a resource group
- a StorageV2 account with public blob access enabled
- a public-read container for screenshot PNGs
- a user-assigned managed identity for GitHub Actions uploads
- GitHub OIDC federated identity credentials for the configured subjects
- `Storage Blob Data Contributor` on the storage account for the upload identity
- an optional lifecycle rule to delete old screenshots

## Authentication Model

GitHub Actions should use OIDC through `azure/login` with the `github_uploader_client_id` output.

Example workflow shape:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_SCREENSHOT_UPLOADER_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

  - name: Upload screenshots
    shell: powershell
    run: |
      az storage blob upload-batch `
        --auth-mode login `
        --account-name $env:AZURE_SCREENSHOT_STORAGE_ACCOUNT `
        --destination $env:AZURE_SCREENSHOT_CONTAINER `
        --destination-path $env:GITHUB_RUN_ID `
        --source $env:SCREENSHOT_DIR `
        --pattern *.png `
        --overwrite true
```

The public preview URL for a screenshot is:

```text
https://<storage-account>.blob.core.windows.net/<container>/<run-id>/<filename>.png
```

## Applying

```powershell
cd infra/opentofu/issue-agent-screenshot-storage
tofu init
tofu plan `
  -var "location=eastus" `
  -var "resource_group_name=rg-spirelens-issue-agent-evidence"
tofu apply
```

The provider can authenticate with Azure CLI locally or OIDC in CI. Backend configuration is intentionally not committed yet; add backend config once we decide where OpenTofu state should live.

## Variables To Export Back To GitHub

After apply, set these repository variables/secrets for the upload workflow:

- `AZURE_SCREENSHOT_UPLOADER_CLIENT_ID` = `github_uploader_client_id`
- `AZURE_SCREENSHOT_STORAGE_ACCOUNT` = `storage_account_name`
- `AZURE_SCREENSHOT_CONTAINER` = `container_name`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`