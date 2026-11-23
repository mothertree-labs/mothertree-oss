# Minimal Synapse configuration for `mas-cli syn2mas` (one-time Synapse →
# MAS migration, #824). apps/deploy-mas.sh fills the empty values with yq
# (strenv, so no password character can break the YAML) into the short-lived
# `mas-syn2mas-synapse` Secret and deleted after the migration.
#
# syn2mas reads server_name and database from here, plus the auth settings
# it validates against the MAS config. It must describe Synapse as it was
# BEFORE the cutover — in particular the Keycloak `oidc_providers` entry —
# otherwise every user_external_ids row (Keycloak link) is reported as
# belonging to an unknown provider instead of being mapped through MAS's
# `synapse_idp_id: oidc-keycloak`. Synapse itself never reads this file.
server_name: ""  # MATRIX_HOST

database:
  name: psycopg2
  args:
    user: ""
    password: ""
    dbname: ""
    host: ""
    port: 5432

enable_registration: false
allow_guest_access: false
password_config:
  enabled: false

oidc_providers:
  - idp_id: keycloak
    idp_name: "Sign in with MotherTree"
    issuer: ""  # https://AUTH_HOST/realms/<realm>
    client_id: "matrix-synapse"
