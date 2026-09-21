import SwiftUI

@main struct ReplyTypographyPreviewApp: App {
    var body: some Scene {
        WindowGroup("正文排版 · 隔离预览") {
            ScrollView {
                KimiMarkdown(text: Self.sample)
                    .frame(maxWidth: ReplyStyle.readingWidth, alignment: .leading)
                    .padding(.horizontal, 32).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }.preferredColorScheme(.light).frame(minWidth: 500, minHeight: 500)
        }.defaultSize(width: 880, height: 760)
    }
    static let sample = """
    # 长回复应像一份排版舒服的笔记，即使标题很长也不抢走正文的注意力

    已完成这轮调整，**现在可以继续推进正文的阅读体验。** 长回复应先让你看清结论，再按需阅读细节。

    这里是一段较长的中英文混排文字，用于检查自动换行和段落之间的距离。Perch 使用 macOS 系统字体，由 TextKit 负责文字选择与排版。中文、English、数字 2026，以及路径 `Sources/AgentWorkbench` 应当协调地出现在同一行中。

    ## 本轮改动

    - **正文**：系统字体与稳定的行高，连续阅读时不显得松散。
    - **信息层级**：标题靠留白自然分段，重点使用 medium 字重，辅助说明保持克制。
      - 嵌套条目保留缩进，较长的解释自然换行，不把正文挤成很窄的一列。
    - **原生交互**：文字可以选择复制，[Markdown 文档](https://commonmark.org/) 保持链接样式。

    ### 验证结果

    | 项目 | 状态 | 说明 |
    | --- | --- | --- |
    | 中文与 English | 已检查 | 同一段落内自然换行 |
    | 文件路径 | 可阅读 | `Sources/Reply.swift` |
    | 完整内容 | 1,024 | 保留表格对齐与边界 |

    > 这是补充说明：引用与正文应有明确区别，但不应该淡到难以阅读。较长的说明同样遵循自然换行，而不是不断拉宽正文。

    ## 代码与操作顺序

    1. 在独立工作区完成修改。
    2. 检查正文、列表和表格，再完成构建。
    3. 保留当前会话，不触碰远端任务。

    ```swift
    struct ReadingLayout {
        let fontSize = 14
        let message = "中文回复与 English 一起阅读"
    }
    ```

    普通文字、**重点结论**、*强调文字*、~~已失效的描述~~ 与 `inlineCode()` 都应该容易辨认。

    #### **标题里的强调**与 `inlineCode()`

    **这是一整段加粗的文字，包含 English 和 `Sources/AgentWorkbench/ReplyMarkdownView.swift`，用于确认强调不会叠加成一大片浓重的黑色。**

    ##### 更深一层的小节

    连续出现的 `session/list`、`session/prompt`、`session/shutdown` 应融入句子，仍然保留等宽字体的辨识度。

    ###### 最深一层的小节

    [普通链接](https://example.com/)、**[强调链接](https://example.com/)** 和 [`代码链接`](https://example.com/) 保持可辨识，也能选择复制。

    ---

    **到这里是完整回复的最后一段。** 缩窄窗口后仍应可读，没有裁切或重叠。
    """
}
