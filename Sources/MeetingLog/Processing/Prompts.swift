import Foundation

enum Prompts {
    static func transcription(context: String, start: Double, end: Double) -> String {
        """
        Transcribe this meeting audio from \(clock(start)) to \(clock(end)).
        Preserve the spoken language. Add speaker labels only when the audio supports them; otherwise use "Speaker".
        Include timestamps at topic or speaker changes. Do not summarize, correct meaning, or invent inaudible words.
        Return Markdown only.

        Known names, projects, jargon, and instructions:
        \(context.isEmpty ? "None provided." : context)
        """
    }

    static func analysis(transcript: String, globalContext: String, projectName: String, projectContext: String) -> String {
        """
        Analyze the meeting transcript below for project "\(projectName)". Infer a concise meeting title in the transcript's language.

        Evidence rules:
        - Use only the transcript and supplied context.
        - Do not add advice or insights.
        - A decision must be explicitly agreed in the transcript. If none, return an empty decisions array.
        - Keep reasoning, action-item context, assignee, and deadline as empty strings when unsupported.
        - Keep every list concise and factual.

        Return one JSON object with exactly these keys:
        {"title":"","projectName":"","summary":[""],"actionItems":[{"assignee":"","task":"","deadline":"","context":""}],"decisions":[{"decision":"","reasoning":""}],"keyTopics":[""]}

        Global context:
        \(globalContext.isEmpty ? "None provided." : globalContext)

        Project context:
        \(projectContext.isEmpty ? "None provided." : projectContext)

        Transcript:
        \(transcript)
        """
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
