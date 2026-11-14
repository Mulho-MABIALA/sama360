/** Tests unitaires : aucun service externe requis. */
module.exports = {
  rootDir: 'src',
  testRegex: '.*\\.spec\\.ts$',
  transform: { '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/../tsconfig.json' }] },
  moduleNameMapper: { '^@sama360/contracts$': '<rootDir>/../../../packages/contracts/src' },
  testEnvironment: 'node',
};
