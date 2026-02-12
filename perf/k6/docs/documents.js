// Document operations for docs load testing
// 
// API Endpoint Configuration:
// - Base path: /api/v1.0 (configurable via DOCS_API_BASE env var)
// - Documents endpoint: /api/v1.0/documents/ (Django REST Framework convention)
//   Alternative endpoints can be configured via DOCS_DOCUMENTS_ENDPOINT env var
// - Uses standard REST verbs: POST (create), GET (retrieve/list), PATCH (update)
// - Returns JSON with 'id' or 'pk' field for created/retrieved documents
//
// The code handles common variations automatically (id vs pk, different endpoint names)

import http from 'k6/http';
import { check } from 'k6';

/**
 * Create a new document
 * @param {string} backendBaseUrl - Base URL of the docs backend (e.g., http://backend.docs.svc.cluster.local:8000)
 * @param {string} token - Keycloak Bearer token
 * @param {object} docData - Document data (title, content, etc.)
 * @returns {object|null} - Document object with id, or null on failure
 */
export function createDocument(backendBaseUrl, token, docData = {}) {
  const apiBase = __ENV.DOCS_API_BASE || '/api/v1.0';
  const documentsPath = __ENV.DOCS_DOCUMENTS_ENDPOINT || 'documents';
  const endpoint = `${backendBaseUrl}${apiBase}/${documentsPath}/`;
  
  const defaultData = {
    title: `Load Test Document ${Date.now()}-${__VU}-${__ITER}`,
    content: 'Initial content from load test',
    ...docData,
  };

  const res = http.post(
    endpoint,
    JSON.stringify(defaultData),
    {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    }
  );

  const created = check(res, {
    'document created': (r) => r.status === 201 || r.status === 200,
  });

  if (!created || (res.status !== 201 && res.status !== 200)) {
    return null;
  }

  try {
    const doc = res.json();
    // Normalize ID field (handle both 'id' and 'pk')
    if (doc && !doc.id && doc.pk) {
      doc.id = doc.pk;
    }
    return doc;
  } catch (e) {
    return null;
  }
}

/**
 * Get a document by ID
 * @param {string} backendBaseUrl - Base URL of the docs backend
 * @param {string} token - Keycloak Bearer token
 * @param {string|number} docId - Document ID
 * @returns {object|null} - Document object or null on failure
 */
export function getDocument(backendBaseUrl, token, docId) {
  const apiBase = __ENV.DOCS_API_BASE || '/api/v1.0';
  const documentsPath = __ENV.DOCS_DOCUMENTS_ENDPOINT || 'documents';
  const endpoint = `${backendBaseUrl}${apiBase}/${documentsPath}/${docId}/`;

  const res = http.get(endpoint, {
    headers: {
      'Authorization': `Bearer ${token}`,
    },
  });

  const retrieved = check(res, {
    'document retrieved': (r) => r.status === 200,
  });

  if (!retrieved) {
    return null;
  }

  try {
    const doc = res.json();
    // Normalize ID field (handle both 'id' and 'pk')
    if (doc && !doc.id && doc.pk) {
      doc.id = doc.pk;
    }
    return doc;
  } catch (e) {
    return null;
  }
}

/**
 * Update an existing document
 * @param {string} backendBaseUrl - Base URL of the docs backend
 * @param {string} token - Keycloak Bearer token
 * @param {string|number} docId - Document ID
 * @param {object} updateData - Fields to update (title, content, etc.)
 * @returns {boolean} - True if update succeeded
 */
export function updateDocument(backendBaseUrl, token, docId, updateData) {
  const apiBase = __ENV.DOCS_API_BASE || '/api/v1.0';
  const documentsPath = __ENV.DOCS_DOCUMENTS_ENDPOINT || 'documents';
  const endpoint = `${backendBaseUrl}${apiBase}/${documentsPath}/${docId}/`;

  const res = http.patch(
    endpoint,
    JSON.stringify(updateData),
    {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    }
  );

  const updated = check(res, {
    'document updated': (r) => r.status === 200 || r.status === 204,
  });

  return updated && (res.status === 200 || res.status === 204);
}

/**
 * List documents (optional, for discovering existing documents)
 * @param {string} backendBaseUrl - Base URL of the docs backend
 * @param {string} token - Keycloak Bearer token
 * @param {object} params - Query parameters (page, limit, etc.)
 * @returns {object|null} - Response object with results array, or null on failure
 */
export function listDocuments(backendBaseUrl, token, params = {}) {
  const apiBase = __ENV.DOCS_API_BASE || '/api/v1.0';
  const documentsPath = __ENV.DOCS_DOCUMENTS_ENDPOINT || 'documents';
  let endpoint = `${backendBaseUrl}${apiBase}/${documentsPath}/`;

  // Add query parameters if provided
  const queryParams = new URLSearchParams();
  if (params.page) queryParams.append('page', params.page);
  if (params.limit) queryParams.append('limit', params.limit);
  if (queryParams.toString()) {
    endpoint += `?${queryParams.toString()}`;
  }

  const res = http.get(endpoint, {
    headers: {
      'Authorization': `Bearer ${token}`,
    },
  });

  const listed = check(res, {
    'documents listed': (r) => r.status === 200,
  });

  if (!listed) {
    return null;
  }

  try {
    const result = res.json();
    // Normalize ID fields in results array if present
    if (result && Array.isArray(result.results)) {
      result.results.forEach(doc => {
        if (doc && !doc.id && doc.pk) {
          doc.id = doc.pk;
        }
      });
    } else if (result && Array.isArray(result)) {
      result.forEach(doc => {
        if (doc && !doc.id && doc.pk) {
          doc.id = doc.pk;
        }
      });
    }
    return result;
  } catch (e) {
    return null;
  }
}

