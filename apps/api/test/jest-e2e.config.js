/** Tests de bout en bout : nécessitent DATABASE_URL (Postgres/Neon de test) et REDIS_URL. */
module.exports = {
  rootDir: '..',
  testRegex: 'test/.*\\.e2e-spec\\.ts$',
  transform: { '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.json' }] },
  moduleNameMapper: { '^@sama360/contracts$': '<rootDir>/../../packages/contracts/src' },
  testEnvironment: 'node',
  testTimeout: 30000,
};
