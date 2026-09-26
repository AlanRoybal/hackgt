import AmazonChimeSDK
import Foundation
import Models

/// Builds a Chime `MeetingSessionConfiguration` from the pass-through JSON in `CallJoin`.
/// Accepts either the bare `Meeting`/`Attendee` objects or the `{ "Meeting": … }` wrappers.
enum ChimeConfig {
    enum ConfigError: Error { case missing(String) }

    static func make(meeting raw: JSONValue, attendee rawAttendee: JSONValue) throws -> MeetingSessionConfiguration {
        let m = raw["Meeting"] ?? raw
        let a = rawAttendee["Attendee"] ?? rawAttendee
        let mp = m["MediaPlacement"]
        func req(_ v: JSONValue?, _ name: String) throws -> String {
            guard let s = v?.stringValue else { throw ConfigError.missing(name) }
            return s
        }
        let placement = MediaPlacement(
            audioFallbackUrl: try req(mp?["AudioFallbackUrl"], "AudioFallbackUrl"),
            audioHostUrl: try req(mp?["AudioHostUrl"], "AudioHostUrl"),
            signalingUrl: try req(mp?["SignalingUrl"], "SignalingUrl"),
            turnControlUrl: try req(mp?["TurnControlUrl"], "TurnControlUrl"),
            eventIngestionUrl: mp?["EventIngestionUrl"]?.stringValue
        )
        let meeting = Meeting(
            externalMeetingId: m["ExternalMeetingId"]?.stringValue,
            mediaPlacement: placement,
            mediaRegion: try req(m["MediaRegion"], "MediaRegion"),
            meetingId: try req(m["MeetingId"], "MeetingId")
        )
        let attendee = Attendee(
            attendeeId: try req(a["AttendeeId"], "AttendeeId"),
            externalUserId: try req(a["ExternalUserId"], "ExternalUserId"),
            joinToken: try req(a["JoinToken"], "JoinToken")
        )
        return MeetingSessionConfiguration(
            createMeetingResponse: CreateMeetingResponse(meeting: meeting),
            createAttendeeResponse: CreateAttendeeResponse(attendee: attendee)
        )
    }

    static func attendeeId(_ rawAttendee: JSONValue) -> String? {
        (rawAttendee["Attendee"] ?? rawAttendee)["AttendeeId"]?.stringValue
    }
}
