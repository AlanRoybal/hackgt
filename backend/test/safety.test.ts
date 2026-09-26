import { describe, expect, it, vi } from 'vitest';
import { isTextHeavy, luhnValid, moderationVerdict, sensitiveTextRules } from '../src/engine/safety.js';

vi.mock('../src/ai/sensitive.js', () => ({ llmSensitiveCheck: vi.fn() }));
const { decideSafety } = await import('../src/lib/photoSafety.js');

describe('moderation filter (mocked Rekognition labels)', () => {
  it('excludes the listed categories above 60% confidence', () => {
    expect(moderationVerdict([{ Name: 'Explicit', Confidence: 90 }]).safe).toBe(false);
    expect(moderationVerdict([{ Name: 'Graphic Violence', ParentName: 'Violence', Confidence: 80 }]).safe).toBe(false);
    expect(moderationVerdict([{ Name: 'Hate Symbols', Confidence: 61 }]).safe).toBe(false);
    expect(moderationVerdict([{ Name: 'Middle Finger', ParentName: 'Rude Gestures', Confidence: 70 }]).safe).toBe(false);
  });
  it('allows low-confidence hits and non-excluded categories', () => {
    expect(moderationVerdict([{ Name: 'Explicit', Confidence: 40 }]).safe).toBe(true);
    expect(moderationVerdict([{ Name: 'Swimwear or Underwear', Confidence: 95 }]).safe).toBe(true);
    expect(moderationVerdict([{ Name: 'Alcohol', Confidence: 95 }]).safe).toBe(true);
    expect(moderationVerdict([]).safe).toBe(true);
  });
});

describe('sensitive text rules', () => {
  it('Luhn', () => {
    expect(luhnValid('4111111111111111')).toBe(true);
    expect(luhnValid('4111111111111112')).toBe(false);
    expect(luhnValid('1234')).toBe(false);
  });
  it.each([
    ['VISA 4111 1111 1111 1111 exp 04/29', 'card'],
    ['5500-0000-0000-0004', 'card'],
    ['SSN 123-45-6789', 'ssn'],
    ['IBAN GB82 WEST 1234 5698 7654 32', 'bank'],
    ['Available balance $2,431.10', 'bank'],
    ['Account number ending 4432', 'bank'],
    ["DRIVER'S LICENSE  DOB 01/02/1990", 'id'],
    ['Passport No. X1234567', 'id'],
    ['Your verification code is 482913', 'credentials'],
    ['WiFi password: hunter2', 'credentials'],
    ['Patient: Jane Doe  Diagnosis: ...', 'medical'],
    ['Rx: Amoxicillin 500mg dosage twice daily', 'medical'],
  ])('%s → %s', (text, cat) => expect(sensitiveTextRules(text)).toContain(cat));
  it.each([
    'Happy birthday Sam!',
    'Joe’s Pizza  Margherita 14.00  Pepperoni 16.00',
    'Trail closes at sunset. Stay on marked paths.',
    'Order #12345 shipped',
    'Call me at 3:40',
    '',
  ])('benign: %s', (text) => expect(sensitiveTextRules(text)).toEqual([]));
  it('text-heavy threshold', () => {
    expect(isTextHeavy('a b c')).toBe(false);
    expect(isTextHeavy('one two three four five six seven eight nine ten eleven twelve')).toBe(true);
  });
});

describe('decideSafety', () => {
  it('moderation hit wins without calling the LLM', async () => {
    const llm = vi.fn();
    const r = await decideSafety([{ Name: 'Explicit', Confidence: 99 }], '', llm);
    expect(r.safe).toBe(false);
    expect(llm).not.toHaveBeenCalled();
  });
  it('rules catch obvious text without the LLM', async () => {
    const llm = vi.fn();
    expect((await decideSafety([], 'Card 4111 1111 1111 1111', llm)).safe).toBe(false);
    expect(llm).not.toHaveBeenCalled();
  });
  it('text-heavy but rule-clean text asks the LLM', async () => {
    const llm = vi.fn().mockResolvedValue({ sensitive: true, category: 'address' });
    const text = 'Jane Doe lives at 12 Elm Street Springfield and her mother maiden name is Smith and more words here';
    expect((await decideSafety([], text, llm)).reason).toBe('llm:address');
    const llm2 = vi.fn().mockResolvedValue({ sensitive: false, category: 'none' });
    expect((await decideSafety([], text, llm2)).safe).toBe(true);
  });
  it('short benign text never calls the LLM', async () => {
    const llm = vi.fn();
    expect((await decideSafety([], 'STOP', llm)).safe).toBe(true);
    expect(llm).not.toHaveBeenCalled();
  });
});
