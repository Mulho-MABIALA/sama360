import { env, resetEnvCache } from './env';

const base = {
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  JWT_ACCESS_SECRET: 'a'.repeat(32),
  JWT_REFRESH_SECRET: 'b'.repeat(32),
  OTP_SECRET: 'c'.repeat(32),
};

describe('configuration', () => {
  const saved = { ...process.env };
  const withEnv = (vars: Record<string, string>) => {
    process.env = { ...vars } as NodeJS.ProcessEnv;
    resetEnvCache();
    return () => env();
  };
  afterAll(() => {
    process.env = saved;
    resetEnvCache();
  });

  it('développement : console par défaut', () => {
    expect(withEnv(base)().OTP_PROVIDER).toBe('console');
  });

  it('production : la console est refusée, sauf dérogation', () => {
    expect(withEnv({ ...base, NODE_ENV: 'production' })).toThrow(/console interdit en production/);
    expect(
      withEnv({
        ...base,
        NODE_ENV: 'production',
        OTP_CONSOLE_IN_PRODUCTION: 'true',
      })().OTP_PROVIDER,
    ).toBe('console');
  });

  it('chaque fournisseur exige ses identifiants', () => {
    expect(withEnv({ ...base, OTP_PROVIDER: 'orange' })).toThrow(/ORANGE_SMS_CLIENT_ID/);
    expect(
      withEnv({
        ...base,
        OTP_PROVIDER: 'orange',
        ORANGE_SMS_CLIENT_ID: 'id',
        ORANGE_SMS_CLIENT_SECRET: 's',
        ORANGE_SMS_SENDER: '+2210000',
      })().OTP_PROVIDER,
    ).toBe('orange');
    expect(
      withEnv({
        ...base,
        OTP_PROVIDER: 'twilio',
        TWILIO_ACCOUNT_SID: 'AC',
        TWILIO_AUTH_TOKEN: 't',
      }),
    ).toThrow(/TWILIO_FROM/);
    expect(withEnv({ ...base, STORAGE_DRIVER: 's3' })).toThrow(/S3_BUCKET/);
  });

  it('proxy et migrations', () => {
    const e = withEnv({
      ...base,
      TRUST_PROXY: '1',
      MIGRATE_ON_START: 'true',
    })();
    expect(e.TRUST_PROXY).toBe(1);
    expect(e.MIGRATE_ON_START).toBe(true);
  });
});
