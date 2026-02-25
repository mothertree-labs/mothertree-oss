module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/__tests__/**/*.test.js'],
  collectCoverageFrom: ['api/**/*.js', 'server.js'],
  coverageDirectory: 'coverage',
};
