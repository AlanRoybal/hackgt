// Amazon Chime SDK Meetings wrapper.
import {
  ChimeSDKMeetingsClient,
  CreateAttendeeCommand,
  CreateMeetingCommand,
  DeleteMeetingCommand,
  StartMeetingTranscriptionCommand,
} from '@aws-sdk/client-chime-sdk-meetings';

const chime = new ChimeSDKMeetingsClient({ region: 'us-east-1' });

export async function createMeeting(callId: string, userIds: string[]) {
  const m = await chime.send(
    new CreateMeetingCommand({ ClientRequestToken: callId, MediaRegion: 'us-east-1', ExternalMeetingId: callId }),
  );
  const meeting = m.Meeting!;
  const attendees: Record<string, any> = {};
  for (const uid of userIds) {
    const a = await chime.send(new CreateAttendeeCommand({ MeetingId: meeting.MeetingId!, ExternalUserId: uid }));
    attendees[uid] = a.Attendee;
  }
  return { meeting, attendees };
}

/**
 * Starts Chime live transcription (D-106) as a fallback transcript source: if the device can't run its own
 * Transcribe stream alongside Chime's audio, it forwards its own attendee's lines from Chime's transcript events.
 * Best-effort — a failure here must never block the call.
 */
export async function startTranscription(meetingId: string): Promise<boolean> {
  if ((process.env.MEETING_TRANSCRIPTION ?? 'on') !== 'on') return false;
  try {
    await chime.send(
      new StartMeetingTranscriptionCommand({
        MeetingId: meetingId,
        TranscriptionConfiguration: { EngineTranscribeSettings: { LanguageCode: 'en-US', Region: 'us-east-1' } },
      }),
    );
    console.log(JSON.stringify({ msg: 'meeting transcription started', meetingId }));
    return true;
  } catch (e) {
    console.warn(JSON.stringify({ msg: 'meeting transcription failed', meetingId, error: (e as any)?.name, detail: String((e as any)?.message) }));
    return false;
  }
}

export async function deleteMeeting(meetingId: string) {
  try {
    await chime.send(new DeleteMeetingCommand({ MeetingId: meetingId }));
  } catch (e) {
    if ((e as any)?.name !== 'NotFoundException') console.warn('delete meeting failed', (e as any)?.name);
  }
}
