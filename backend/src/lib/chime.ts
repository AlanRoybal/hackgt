// Amazon Chime SDK Meetings wrapper.
import {
  ChimeSDKMeetingsClient,
  CreateAttendeeCommand,
  CreateMeetingCommand,
  DeleteMeetingCommand,
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

export async function deleteMeeting(meetingId: string) {
  try {
    await chime.send(new DeleteMeetingCommand({ MeetingId: meetingId }));
  } catch (e) {
    if ((e as any)?.name !== 'NotFoundException') console.warn('delete meeting failed', (e as any)?.name);
  }
}
