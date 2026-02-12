# Docs Load Testing

This directory contains k6 load tests for the LaSuite Docs application.

## Test Scripts

- **`load.js`** - Main load test with document editing operations
- **`smoke.js`** - Quick smoke test to verify basic functionality
- **`discover.js`** - API endpoint discovery script (run this first to validate assumptions)
- **`auth.js`** - Keycloak authentication helper
- **`documents.js`** - Document CRUD operations helper

## API Endpoint Discovery

The document editing functionality makes assumptions about the API structure based on Django REST Framework conventions. To validate these assumptions:

1. **Run the discovery script:**
   ```bash
   k6 run discover.js --env-file=../../env/dev.env
   ```

2. **Review the output** to see which endpoints actually exist and work

3. **Update `documents.js`** if the actual endpoints differ from assumptions:
   - Common variations:
     - `/api/v1.0/pages/` instead of `/api/v1.0/documents/`
     - `/api/v1.0/docs/` instead of `/api/v1.0/documents/`
     - Different field names in request/response (e.g., `pk` instead of `id`)

## Configuration

Key environment variables (see `../../env/dev.env`):

- `DOCS_BACKEND_BASE_URL` - Backend service URL
- `DOCS_FRONTEND_BASE_URL` - Frontend service URL
- `DOCS_API_BASE` - API base path (default: `/api/v1.0`)
- `DOCS_ENABLE_DOCUMENT_EDITING` - Enable document operations (default: `1`, set to `0` to disable)
- `DOCS_PROTECTED_PATH` - Optional protected endpoint to test
- `KEYCLOAK_*` - Keycloak authentication settings
- `USERS_CSV_PATH` or `USERS_CSV_INLINE` - CSV file with test users (username,password format)

## Running Tests

### Discovery (First Time)
```bash
k6 run discover.js --env-file=../../env/dev.env
```

### Smoke Test
```bash
k6 run smoke.js --env-file=../../env/dev.env
```

### Load Test
```bash
k6 run load.js --env-file=../../env/dev.env
```

## Configuration

The code uses standard Django REST Framework conventions but is configurable:

1. **API Base**: `/api/v1.0` (configurable via `DOCS_API_BASE`)
2. **Documents Endpoint**: `/api/v1.0/documents/` (configurable via `DOCS_DOCUMENTS_ENDPOINT`)
   - Default: `documents`
   - Alternatives: `pages`, `docs`, etc.
3. **HTTP Methods**:
   - `POST /api/v1.0/{DOCS_DOCUMENTS_ENDPOINT}/` - Create document
   - `GET /api/v1.0/{DOCS_DOCUMENTS_ENDPOINT}/{id}/` - Get document
   - `PATCH /api/v1.0/{DOCS_DOCUMENTS_ENDPOINT}/{id}/` - Update document
4. **Request Format**: JSON with `title`, `content` fields
5. **Response Format**: JSON with `id` or `pk` field (handled automatically)

The code automatically handles:
- ID field variations (`id` vs `pk`)
- Different endpoint names (configurable)
- Standard HTTP status codes (200, 201, 204)

If the default assumptions don't match your API, you can:
1. Run `discover.js` to find the actual endpoints
2. Set `DOCS_DOCUMENTS_ENDPOINT` environment variable to the correct endpoint name
3. Adjust `DOCS_API_BASE` if the API base path differs

