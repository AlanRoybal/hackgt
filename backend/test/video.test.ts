import { describe, expect, it } from 'vitest';
import { parseVideoCaption } from '../src/ai/caption.js';
import { MAX_VIDEO_MS, mediaTypeOf, videoDuration } from '../src/lib/media.js';
import { photoKey, videoKey } from '../src/lib/s3.js';

describe('video upload items', () => {
  it('treats items without a media type as photos', () => {
    expect(videoDuration({})).toBeNull();
    expect(videoDuration({ mediaType: 'photo', durationMs: 9000 })).toBeNull();
  });
  it('accepts short videos and rounds their length', () => {
    expect(videoDuration({ mediaType: 'video', durationMs: 4200.4 })).toBe(4200);
    // Container durations can run a few frames over the cap.
    expect(videoDuration({ mediaType: 'video', durationMs: MAX_VIDEO_MS + 200 })).toBe(MAX_VIDEO_MS);
  });
  it.each([
    { mediaType: 'video' },
    { mediaType: 'video', durationMs: 0 },
    { mediaType: 'video', durationMs: 'long' },
    { mediaType: 'video', durationMs: 45_000 },
    { mediaType: 'gif', durationMs: 2000 },
  ])('skips %o', (item) => expect(videoDuration(item)).toBeUndefined());
  it('mediaTypeOf defaults to photo', () => {
    expect(mediaTypeOf(undefined)).toBe('photo');
    expect(mediaTypeOf({ mediaType: 'video' })).toBe('video');
  });
  it('keeps the clip next to its poster under photos/', () => {
    expect(photoKey('u', 'h')).toBe('photos/u/h.jpg');
    expect(videoKey('u', 'h')).toBe('photos/u/h.mp4');
  });
});

describe('video caption parsing', () => {
  it('reads caption and sensitivity', () => {
    expect(parseVideoCaption('```json\n{"caption": "A dog chases a frisbee on a beach.", "sensitive": false}\n```'))
      .toEqual({ caption: 'A dog chases a frisbee on a beach.', sensitive: false });
    expect(parseVideoCaption('{"caption": "x", "sensitive": yes}')?.sensitive).toBe(true);
  });
  it('rejects empty or missing captions', () => {
    expect(parseVideoCaption('{"caption": "  "}')).toBeUndefined();
    expect(parseVideoCaption('A dog on a beach.')).toBeUndefined();
  });
});
