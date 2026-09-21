import SwiftUI

@main struct ReplyTypographyPreviewApp: App {
    @State private var columnWidth = ReplyStyle.readingWidth
    var body: some Scene {
        WindowGroup("正文排版 · 隔离预览") {
            VStack(spacing: 0) {
                Picker("阅读宽度", selection: $columnWidth) {
                    Text("窄栏 420").tag(CGFloat(420))
                    Text("正文 700").tag(ReplyStyle.readingWidth)
                    Text("原宽 760").tag(CGFloat(760))
                }.pickerStyle(.segmented).frame(width: 320).padding(16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        KimiMarkdown(text: "可以，已经保留文字颜色。下一步查看长回复的阅读节奏。")
                        Divider()
                        KimiMarkdown(text: Self.sample)
                        ReplyCopyButton(text: Self.sample)
                    }
                    .frame(maxWidth: columnWidth, alignment: .leading)
                    .padding(.horizontal, 32).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
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

    - 分支：`feat/example`，提交 `abc1234`（基于 `origin/main`）。
    - Mac 上运行 `git fetch origin && git checkout feat/example`，然后执行 `./scripts/build.sh`。
      1. 参数 `--example-option` 位于嵌套列表中，行内代码应保持等宽，周围没有高出文字的灰色矩形。
      2. 联系地址 `reader@example.com` 与中文、English 混排时，底色保持一致。

    ## 列表与段落的阅读节奏

    - 单行项目一。
    - 单行项目二。
    - 这是一条会随着窗口缩窄而变成多行的说明，用于检查换行后与前后条目的距离。继续补充足够长的中文与 English 内容，确认文字仍与第一行正文对齐，不会回到圆点下方，也不会与下一项挤在一起。
    - 多行说明后的短项目。

    9. 保留列表原本的起始编号。
    10. 第二项包含后续段落。

        这是同一项的补充说明，间距应小于独立正文段落，仍与本项文字对齐。

        - 嵌套条目保持从属关系。
        - 第二个嵌套条目。

    ## 长路径、链接与表格

    行内路径 `Sources/AgentWorkbench/Features/Conversation/Components/Rendering/Typography/LongDirectoryNameWithoutSpaces/ReplyMarkdownView.swift` 应自然换行，选择复制后仍是一条完整路径。

    [https://example.com/documentation/conversation/rendering/typography/LongResourceNameWithoutSpacesToCheckWrappingAndSelectionAtNarrowWidths](https://example.com/documentation/conversation/rendering/typography/LongResourceNameWithoutSpacesToCheckWrappingAndSelectionAtNarrowWidths)

    | 项目 | 文件或说明 | 数量 |
    | :--- | :--- | ---: |
    | 长路径 | `Sources/AgentWorkbench/Features/Conversation/Components/Rendering/Typography/ReplyMarkdownView.swift` | 12 |
    | 长链接 | [阅读完整的中文与 English 排版说明，检查单元格自然换行](https://example.com/reading) | 3 |

    下表列数较多，只在表格内部横向滚动，正文宽度应保持一致。

    | 项目 | A | B | C | D | E | F |
    | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
    | 演示数据 | 10 | 20 | 30 | 40 | 50 | 60 |

    ###### 最深一层的小节

    [普通链接](https://example.com/)、**[强调链接](https://example.com/)** 和 [`代码链接`](https://example.com/) 保持可辨识，也能选择复制。

    ---

    **到这里是完整回复的最后一段。** 缩窄窗口后仍应可读，没有裁切或重叠。
    """
}
