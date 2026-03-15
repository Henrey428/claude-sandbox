# Main on feature-x, shared-lib on feature-x too
claude-sandbox \
  --main myorg/api-service@feature-x \
  --repo myorg/shared-lib@feature-x

# Different branches per repo
claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib@v2-refactor \
  --repo myorg/infra-config@staging

# No branch = default branch (main/master)
claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib

# With Claude prompt
claude-sandbox \
  --main myorg/api-service@fix-auth \
  --repo myorg/shared-lib@fix-auth \
  --claude "Fix the auth middleware using the updated types from shared-lib"