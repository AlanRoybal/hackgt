// Photos and short videos share one index; these are the rules that differ for videos (SPEC VID-1..4).

export type MediaType = 'photo' | 'video';

/** Longest clip the phone uploads and the call plays (VID-1). */
export const MAX_VIDEO_MS = 30_000;
/** Above this the clip isn't sent to Nova; the poster frame is captioned instead (Converse caps inline bytes at 25 MB). */
export const MAX_VIDEO_CAPTION_BYTES = 20 * 1024 * 1024;

export const mediaTypeOf = (item: Record<string, any> | undefined): MediaType => (item?.mediaType === 'video' ? 'video' : 'photo');

/**
 * Validates the video fields of an upload item. Returns the clip length in ms for a valid video,
 * `null` for a photo, or `undefined` when the item must be skipped.
 */
export function videoDuration(item: Record<string, any>): number | null | undefined {
  if (item.mediaType === undefined || item.mediaType === 'photo') return null;
  if (item.mediaType !== 'video') return undefined;
  const ms = Number(item.durationMs);
  if (!Number.isFinite(ms) || ms <= 0 || ms > MAX_VIDEO_MS + 500) return undefined;
  return Math.round(Math.min(ms, MAX_VIDEO_MS));
}
