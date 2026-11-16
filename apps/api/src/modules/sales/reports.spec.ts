import { bucketsOf, changePct, granularity, previousPeriod, spanDays } from './reports';

describe('périodes des rapports', () => {
  it('durée et période précédente', () => {
    expect(spanDays('2026-11-16', '2026-11-16')).toBe(1);
    expect(spanDays('2026-11-01', '2026-11-30')).toBe(30);
    expect(previousPeriod('2026-11-16', '2026-11-16')).toEqual({ from: '2026-11-15', to: '2026-11-15' });
    expect(previousPeriod('2026-11-10', '2026-11-16')).toEqual({ from: '2026-11-03', to: '2026-11-09' });
    expect(previousPeriod('2026-03-01', '2026-03-31')).toEqual({ from: '2026-01-29', to: '2026-02-28' });
  });

  it('série continue par jour ou par mois', () => {
    expect(granularity('2026-11-01', '2026-11-30')).toBe('day');
    expect(granularity('2026-01-01', '2026-12-31')).toBe('month');
    expect(bucketsOf('2026-11-28', '2026-12-02', 'day')).toEqual([
      '2026-11-28',
      '2026-11-29',
      '2026-11-30',
      '2026-12-01',
      '2026-12-02',
    ]);
    expect(bucketsOf('2025-11-15', '2026-02-10', 'month')).toEqual(['2025-11', '2025-12', '2026-01', '2026-02']);
  });

  it('évolution en %', () => {
    expect(changePct(15000, 10000)).toBe(50);
    expect(changePct(7000, 10000)).toBe(-30);
    expect(changePct(5000, 0)).toBeNull();
  });
});
