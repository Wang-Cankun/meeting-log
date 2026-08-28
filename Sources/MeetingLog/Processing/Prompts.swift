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

    static func projectInference(transcript: String, globalContext: String, projectContexts: [ProjectContext]) -> String {
        let projects = projectContexts.map { "## \($0.slug)\n\($0.markdown)" }.joined(separator: "\n\n")
        return """
        Infer a concise meeting title and the best project for this transcript. Reuse an existing project slug when its context clearly matches; otherwise create a concise lowercase ASCII kebab-case slug. Return JSON only:
        {"title":"","projectName":"","projectSlug":""}

        Global context:
        \(globalContext.isEmpty ? "None provided." : globalContext)

        Existing projects:
        \(projects.isEmpty ? "None." : projects)

        Transcript:
        \(transcript)
        """
    }

    static func analysis(transcript: String, globalContext: String, project: ProjectChoice, projectContext: String) -> String {
        """
        Analyze the meeting transcript below for project "\(project.projectName)" (\(project.projectSlug)). Use the supplied title "\(project.title)".

        Evidence rules:
        - Use only the transcript and supplied context.
        - Do not add advice or insights.
        - A decision must be explicitly agreed in the transcript. If none, return an empty decisions array.
        - Keep reasoning, action-item context, assignee, and deadline as empty strings when unsupported.
        - Keep every list concise and factual.

        Return one JSON object with exactly these keys:
        {"title":"","projectName":"","projectSlug":"","summary":[""],"actionItems":[{"assignee":"","task":"","deadline":"","context":""}],"decisions":[{"decision":"","reasoning":""}],"keyTopics":[""]}

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
