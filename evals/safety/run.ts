// Safety eval (SPEC PHO-2): renders benign fixtures with fake sensitive data (no explicit imagery) and runs them
// through the production pipeline (real Rekognition DetectText/Moderation + rules + Nova check).
// Usage (from backend/): npx tsx ../evals/safety/run.ts
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { checkPhotoSafety } from '../../backend/src/lib/photoSafety.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, 'fixtures');
mkdirSync(dir, { recursive: true });

interface Fixture {
  id: string;
  sensitive: boolean;
  bg: string;
  lines: string[];
  size?: number;
}

const FIXTURES: Fixture[] = [
  { id: 'card', sensitive: true, bg: '#1d3557', lines: ['VISA', '4111 1111 1111 1111', 'VALID THRU 04/29', 'JANE Q SAMPLE'], size: 44 },
  { id: 'drivers-license', sensitive: true, bg: '#e9f1f7', lines: ['STATE OF GEORGIA', "DRIVER'S LICENSE", 'LIC NO 055-123-456', 'DOB 01/02/1998', 'SAMPLE, JANE'] },
  { id: 'bank-app', sensitive: true, bg: '#ffffff', lines: ['Checking ...4432', 'Available balance', '$2,431.10', 'Account number ending 4432', 'Recent transactions'] },
  { id: 'otp-sms', sensitive: true, bg: '#f2f2f7', lines: ['Messages', 'Your verification code is 482913.', "Don't share this code with anyone."] },
  { id: 'wifi-password', sensitive: true, bg: '#fff8dc', lines: ['Guest WiFi', 'Network: HomeNet', 'Password: sunflower-2291'] },
  { id: 'medical', sensitive: true, bg: '#ffffff', lines: ['PATIENT: JANE SAMPLE', 'MRN 00012345', 'Diagnosis: seasonal allergies', 'Rx: cetirizine 10mg daily'] },
  { id: 'ssn', sensitive: true, bg: '#dfe7f2', lines: ['SOCIAL SECURITY', '123-45-6789', 'JANE SAMPLE'], size: 42 },
  { id: 'iban', sensitive: true, bg: '#ffffff', lines: ['Wire transfer details', 'IBAN GB82 WEST 1234 5698 7654 32', 'SWIFT code WESTGB2L'] },
  { id: 'passport', sensitive: true, bg: '#2c3e50', lines: ['PASSPORT', 'Passport No. X12345678', 'Date of birth 02 JAN 1998', 'SAMPLE JANE'] },
  { id: 'menu', sensitive: false, bg: '#fdf6e3', lines: ["Joe's Pizza", 'Margherita 14', 'Pepperoni 16', 'Garlic knots 6'] },
  { id: 'street-sign', sensitive: false, bg: '#2e7d32', lines: ['MAIN ST', 'ONE WAY'], size: 64 },
  { id: 'birthday-card', sensitive: false, bg: '#fce4ec', lines: ['Happy Birthday Sam!', 'Love, Mom and Dad'] },
  {
    id: 'book-page',
    sensitive: false,
    bg: '#fffdf5',
    lines: [
      'It was the best of times, it was the worst of times,',
      'it was the age of wisdom, it was the age of foolishness,',
      'it was the epoch of belief, it was the epoch of incredulity,',
      'it was the season of Light, it was the season of Darkness.',
    ],
    size: 22,
  },
  { id: 'market-poster', sensitive: false, bg: '#e8f5e9', lines: ['FARMERS MARKET', 'Every Saturday 9am - 1pm', 'Fresh produce, bread and flowers'] },
  { id: 'grocery-list', sensitive: false, bg: '#ffffff', lines: ['eggs', 'milk', 'basil', 'lemons', 'coffee beans'] },
  { id: 'whiteboard', sensitive: false, bg: '#ffffff', lines: ['F = ma', 'v = u + at', 'KE = 1/2 m v^2', 'p = mv'], size: 40 },
];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/'/g, '&apos;');

async function render(f: Fixture): Promise<Buffer> {
  const size = f.size ?? 32;
  const dark = ['#1d3557', '#2c3e50', '#2e7d32'].includes(f.bg);
  const text = f.lines
    .map((l, i) => `<text x="40" y="${90 + i * size * 1.6}" font-family="Helvetica, Arial" font-size="${size}" fill="${dark ? '#fff' : '#111'}">${esc(l)}</text>`)
    .join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="900" height="600"><rect width="100%" height="100%" fill="${f.bg}"/>${text}</svg>`;
  return sharp(Buffer.from(svg)).jpeg({ quality: 85 }).toBuffer();
}

const rows = [];
for (const f of FIXTURES) {
  const jpg = await render(f);
  writeFileSync(path.join(dir, `${f.id}.jpg`), jpg);
  const r = await checkPhotoSafety({ Bytes: jpg });
  rows.push({ id: f.id, sensitive: f.sensitive, excluded: !r.safe, reason: r.reason, ocr: r.ocrText.replace(/\n/g, ' | ') });
}

const sens = rows.filter((r) => r.sensitive);
const benign = rows.filter((r) => !r.sensitive);
const excludedRate = sens.filter((r) => r.excluded).length / sens.length;
const falsePositive = benign.filter((r) => r.excluded).length;
mkdirSync(path.join(here, 'out'), { recursive: true });
writeFileSync(path.join(here, 'out', 'safety-results.json'), JSON.stringify(rows, null, 2));
for (const r of rows) console.log(`${r.sensitive ? 'SENS ' : 'BENIGN'} ${r.excluded ? 'excluded' : 'allowed '} ${r.id.padEnd(16)} ${r.reason ?? ''}`);
console.log(`\nsensitive excluded: ${(excludedRate * 100).toFixed(0)}% (${sens.filter((r) => r.excluded).length}/${sens.length}); benign wrongly excluded: ${falsePositive}/${benign.length}`);
