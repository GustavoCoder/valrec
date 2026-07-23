---
mode: agent
description: One-time prompt — HashiCorp Vault credential provider + SQL connection factory used by ALL database access
---
Implement Vault-backed SQL Server credential management: a credential provider that
authenticates to HashiCorp Vault via TLS certificate and a connection factory that all
database access (EF, Dapper, SqlBulkCopy, Hangfire) uses. Security-critical shared
infrastructure — clarity over cleverness.

CONTEXT
- Repo invariants: #file:.github/copilot-instructions.md (Vault rule)
- Consumers to refit: src/Valrec.Infrastructure/Ingestion/Staging/StagingWriter.cs and
  any existing direct SqlConnection/connection-string usage.

CONFIGURATION (bind from IConfiguration section "Vault"; validate on startup with
ValidateDataAnnotations + ValidateOnStart)
```csharp
public sealed class VaultOptions
{
    public required Uri Url { get; init; }
    public required string CertificatePath { get; init; }   // client cert for TLS cert auth
    public string? CertificatePassword { get; init; }        // from env var, never appsettings
    public required string Namespace { get; init; }          // Vault Enterprise namespace
    public required Dictionary<string, string> AccountPaths { get; init; }
    // logical account name -> Vault secret path, e.g. "valrec-app": "database/creds/valrec-app",
    // "valrec-hangfire": "...". Multiple accounts supported; consumers ask by logical name.
}
```

DESIGN
1. **IVaultCredentialProvider** (Application port; implementation in Infrastructure):
   `Task<SqlCredentialLease> GetCredentialsAsync(string accountName, CancellationToken ct)`
   - Authenticate to Vault via TLS certificate auth method, honoring Namespace.
   - Support BOTH secret shapes behind the same call: dynamic database credentials
     (lease with TTL) and static KV (username/password fields). Detect from response.
   - Cache per accountName. For leased credentials: proactively renew/refresh at a
     configurable fraction of TTL (default 0.75) via a background timer; on renewal
     failure fetch fresh. For static: refresh on a configurable interval and on
     authentication failure signal (see 2).
   - Thread-safe: concurrent callers for the same account share one in-flight fetch
     (no stampede).
2. **ISqlConnectionFactory** (Application port):
   `Task<SqlConnection> CreateOpenConnectionAsync(string accountName, CancellationToken ct)`
   - Builds the connection string from configuration (server, database, options — NO
     credentials in it) + SqlCredential from the provider (SecureString per SqlCredential API).
   - On SQL auth failure (error 18456) exactly once: invalidate the cached credential,
     re-fetch from Vault, retry the open — handles rotation races. Then rethrow.
   - Polly: retry with jitter on transient Vault/SQL errors (bounded attempts).
3. **Integration**: refit StagingWriter and Hangfire storage configuration to use the
   factory (Hangfire: connection factory delegate). EF DbContext (when created later)
   will use it too — leave a documented extension point.
4. **Health check**: "vault" health check that verifies auth + one credential fetch
   (result cached briefly; never hammer Vault from health probes).
5. **Logging**: account name, lease TTL, renewal events — NEVER usernames, passwords,
   tokens, or lease IDs. Add a test asserting the credential type has no usable ToString.

PACKAGE EXCEPTION
- You MAY add VaultSharp (latest stable) to Valrec.Infrastructure. No other new packages.

TESTS
- Unit: provider caching (second call = no fetch), single-flight under concurrency,
  renewal-at-TTL-fraction scheduling, 18456 → single refetch-and-retry then rethrow,
  options validation failures. Mock the Vault client behind a thin IVaultApi seam so
  tests don't need a live Vault.
- Integration (Testcontainers): factory + StagingWriter end-to-end against SQL Server
  using a stubbed provider returning container credentials — proves the factory path,
  not Vault itself.

ACCEPTANCE
- Build zero warnings; tests green; architecture tests green (ports in Application,
  VaultSharp only referenced from Infrastructure).
- Grep-clean: no "Password=" / "User ID=" in any config file or connection string literal.

CONSTRAINTS
- Do not implement AppRole/token/userpass auth — TLS certificate auth only.
- Do not build a general secrets framework; SQL credentials only.
- If the Vault response shape for the configured paths is ambiguous, STOP and list what
  you need confirmed (dynamic vs KV, field names) instead of guessing.
