// Shared k6 thresholds and options helpers

export function buildOptions(appName) {
  const env = __ENV.ENV || 'dev';
  return {
    thresholds: {
      http_req_failed: ['rate<0.01'],
      http_req_duration: ['p(95)<500'],
    },
    tags: { env, app: appName },
  };
}



