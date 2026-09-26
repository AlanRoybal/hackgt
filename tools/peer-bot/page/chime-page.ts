// Runs inside headless Chrome. Joins a Chime meeting with fake media and relays `photo` data messages.
import {
  ConsoleLogger,
  DefaultDeviceController,
  DefaultMeetingSession,
  LogLevel,
  MeetingSessionConfiguration,
  type AudioVideoObserver,
  type DataMessage,
} from "amazon-chime-sdk-js";

declare global {
  interface Window {
    __onData: (json: string, timestampMs: number, senderAttendeeId: string) => void;
    __onEvent: (name: string, detail: string) => void;
    nudgeBot: typeof api;
  }
}

let session: DefaultMeetingSession | undefined;

const api = {
  stage: "idle",
  async join(meeting: unknown, attendee: unknown): Promise<void> {
    api.stage = "config";
    const logger = new ConsoleLogger("bot", (window as any).__chimeLogLevel ?? LogLevel.WARN);
    const devices = new DefaultDeviceController(logger);
    const config = new MeetingSessionConfiguration(meeting, attendee);
    session = new DefaultMeetingSession(config, logger, devices);
    const av = session.audioVideo;
    const started = new Promise<void>((resolve, reject) => {
      const observer: AudioVideoObserver = {
        audioVideoDidStart: () => resolve(),
        audioVideoDidStop: (s) => {
          window.__onEvent("stopped", String(s.statusCode()));
          reject(new Error(`stopped ${s.statusCode()}`));
        },
      };
      av.addObserver(observer);
    });
    av.realtimeSubscribeToAttendeeIdPresence((id, present) => window.__onEvent("presence", JSON.stringify({ id, present })));
    av.realtimeSubscribeToReceiveDataMessage("photo", (m: DataMessage) =>
      window.__onData(m.text(), m.timestampMs, m.senderAttendeeId),
    );
    api.stage = "devices";
    if (!(window as any).__noMedia) {
      const mics = await av.listAudioInputDevices();
      if (mics[0]) await av.startAudioInput(mics[0].deviceId);
      const cams = await av.listVideoInputDevices();
      if (cams[0]) await av.startVideoInput(cams[0].deviceId);
    }
    api.stage = "starting";
    av.start();
    await started;
    api.stage = "started";
    if (!(window as any).__noMedia) av.startLocalVideoTile();
  },

  send(json: string): void {
    session?.audioVideo.realtimeSendDataMessage("photo", json, 10000);
  },

  async leave(): Promise<void> {
    session?.audioVideo.stop();
  },

  /** Render a labeled test "photo" to a JPEG (base64) — no image files needed. */
  makePhoto(label: string, hue: number): string {
    const c = document.createElement("canvas");
    c.width = 1024;
    c.height = 768;
    const g = c.getContext("2d")!;
    g.fillStyle = `hsl(${hue} 60% 80%)`;
    g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = `hsl(${hue} 50% 35%)`;
    g.beginPath();
    g.arc(700, 300, 160, 0, Math.PI * 2);
    g.fill();
    g.font = "bold 72px system-ui";
    g.fillText(label, 60, 680);
    return c.toDataURL("image/jpeg", 0.85).split(",")[1];
  },
};

window.nudgeBot = api;
window.__onEvent?.("ready", "");
