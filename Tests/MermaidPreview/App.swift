import SwiftUI

@main struct MermaidPreviewApp: App {
    var body: some Scene {
        WindowGroup("Mermaid 预览") {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    KimiMarkdown(text: Self.flowchart)
                    KimiMarkdown(text: Self.sequence)
                    KimiMarkdown(text: Self.broken)
                    KimiMarkdown(text: Self.plainCode)
                }
                .frame(maxWidth: ReplyStyle.readingWidth, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .preferredColorScheme(.light).frame(minWidth: 500, minHeight: 500)
        }.defaultSize(width: 880, height: 1100)
    }
    static let flowchart = """
    下面是流程图的渲染效果：

    ```mermaid
    graph LR
      A[用户提问] --> B{是否需要工具}
      B -->|是| C[调用工具]
      B -->|否| D[直接回答]
      C --> D
    ```

    图后的正文段落保持原有排版。
    """
    static let sequence = """
    ```mermaid
    sequenceDiagram
      participant U as 用户
      participant P as Perch
      participant A as Agent
      U->>P: 发送问题
      P->>A: 转发请求
      A-->>P: 流式回复
      P-->>U: 渲染正文
    ```
    """
    static let broken = """
    下面这个 mermaid 语法有误，应回退为代码卡：

    ```mermaid
    graph TD
      A[未闭合 --> B
    ```
    """
    static let plainCode = """
    ```swift
    let ordinary = "普通代码块不受影响"
    ```
    """
}
