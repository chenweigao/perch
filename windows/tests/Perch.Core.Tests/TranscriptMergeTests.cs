using Perch.Core.Protocol;
using Perch.Core.State;

namespace Perch.Core.Tests;

/// Transcript merge correctness against the real bridge fixtures. The bridge streams by
/// replacing message positions and naming changed indices in a delta; merging by index
/// is what stops repeated polls from re-appending the growing reply, and the epoch /
/// baseRevision / start guards are what stop a stale response from corrupting the view.
public class TranscriptMergeTests
{
    private static BridgeSnapshot Read(string name) => Fixtures.Read<BridgeSnapshot>(name);

    [Fact]
    public void FirstPagedSnapshotEstablishesTheWindow()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        Assert.Equal("ses-busy", transcript.SessionId);
        Assert.Equal(0, transcript.Start);
        Assert.Equal(2, transcript.Total);
        Assert.False(transcript.HasOlder);
        Assert.NotNull(transcript.Epoch);
        // user prompt + streaming assistant reply
        Assert.Equal(2, transcript.Messages.Count);
        Assert.Contains("正在处理 中文 🚀", transcript.Messages[1].Content.Single().Text);
    }

    [Fact]
    public void DeltaReplacesTheStreamingReplyInPlaceInsteadOfAppending()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var before = transcript.Messages.Count;

        var delta = Read("session-snapshot-delta.json");
        Assert.True(transcript.TryApplyDelta(delta, out var needsFull));
        Assert.False(needsFull);

        // Same count: the reply was replaced, not duplicated.
        Assert.Equal(before, transcript.Messages.Count);
        Assert.Equal(2, transcript.Messages.Count);
        // The grown text is at index 1, exactly where the streaming reply lives.
        Assert.Equal("正在处理 中文 🚀 完成 ✅", transcript.Messages[1].Content.Single().Text);
        Assert.Equal(delta.Revision, transcript.Revision);
    }

    [Fact]
    public void RepeatedDeltasAtTheSameRevisionNeverDuplicate()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var delta = Read("session-snapshot-delta.json");
        Assert.True(transcript.TryApplyDelta(delta, out _));
        // Re-applying the identical delta (a poll that raced) is a no-op-safe replace:
        // baseRevision now differs, so it asks for a full read rather than corrupting.
        var second = transcript.TryApplyDelta(delta, out var needsFull);
        Assert.False(second);
        Assert.True(needsFull);
        // Crucially the transcript is unchanged and not doubled.
        Assert.Equal(2, transcript.Messages.Count);
        Assert.Equal("正在处理 中文 🚀 完成 ✅", transcript.Messages[1].Content.Single().Text);
    }

    [Fact]
    public void DeltaAppendExtendsTheTranscriptWithToolUseAndResult()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        Assert.True(transcript.TryApplyDelta(Read("session-snapshot-delta.json"), out _));
        Assert.True(transcript.TryApplyDelta(Read("session-snapshot-delta-append.json"), out var needsFull));
        Assert.False(needsFull);

        // Two original messages + tool_use + tool_result, in index order, no duplicates.
        Assert.Equal(4, transcript.Messages.Count);
        Assert.Equal("codex:item-1", transcript.Messages[1].Id);
        Assert.Equal("codex-tool:item-2", transcript.Messages[2].Id);
        Assert.Equal("codex-result:item-2", transcript.Messages[3].Id);
    }

    [Fact]
    public void DeltaForAnotherSessionIsIgnored()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var other = Read("session-snapshot-delta.json") with { Id = "ses-other" };
        Assert.False(transcript.TryApplyDelta(other, out var needsFull));
        Assert.False(needsFull);
        Assert.Equal(2, transcript.Messages.Count); // untouched
    }

    [Fact]
    public void StaleEpochForcesAFullReadRatherThanMerging()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        // A delta claiming a different epoch means history was replaced on the bridge.
        var stale = Read("session-snapshot-delta.json");
        stale = stale with { History = stale.History! with { Epoch = "deadbeefdeadbeef" } };
        Assert.False(transcript.TryApplyDelta(stale, out var needsFull));
        Assert.True(needsFull);
        Assert.Equal(2, transcript.Messages.Count); // not corrupted by the stale delta
    }

    [Fact]
    public void BaseRevisionMismatchForcesAFullRead()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var append = Read("session-snapshot-delta-append.json");
        // Its baseRevision (4) is ahead of what we hold (revision 3 from the paged read),
        // i.e. we missed the delta that produced it. Merge must refuse and ask for a
        // full read rather than splice onto the wrong base.
        var behind = append with { History = append.History! with { BaseRevision = 99 } };
        Assert.False(transcript.TryApplyDelta(behind, out var needsFull));
        Assert.True(needsFull);
        Assert.Equal(2, transcript.Messages.Count);
    }

    [Fact]
    public void WindowStartMismatchForcesAFullRead()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var shifted = Read("session-snapshot-delta.json");
        shifted = shifted with { History = shifted.History! with { Start = 5 } };
        Assert.False(transcript.TryApplyDelta(shifted, out var needsFull));
        Assert.True(needsFull);
        Assert.Equal(2, transcript.Messages.Count);
    }

    [Fact]
    public void IndicesCountMustMatchMessagesOrForceFullRead()
    {
        var transcript = Transcript.FromFull(Read("session-snapshot-paged.json"));
        var broken = Read("session-snapshot-delta.json");
        // indices names two positions but only one message is carried.
        broken = broken with { History = broken.History! with { Indices = new[] { 0, 1 } } };
        Assert.False(transcript.TryApplyDelta(broken, out var needsFull));
        Assert.True(needsFull);
    }

    [Fact]
    public void MergeRejectsNonAscendingIndices()
    {
        var previous = new List<BridgeMessage> { Msg(0), Msg(1) };
        var changes = new[] { Msg(1), Msg(0) };
        var result = Transcript.Merge(previous, 0, 2, new[] { 1, 0 }, changes);
        Assert.Null(result);
    }

    [Fact]
    public void MergeRejectsAGapItCannotFill()
    {
        var previous = new List<BridgeMessage> { Msg(0) };
        // index 3 named but window total is only 2 → out of range.
        var result = Transcript.Merge(previous, 0, 2, new[] { 3 }, new[] { Msg(3) });
        Assert.Null(result);
    }

    [Fact]
    public void MergeFillsToTotalWhenDeltaDescribesTheTail()
    {
        var previous = new List<BridgeMessage> { Msg(0), Msg(1) };
        // Append at index 2 (the end) with total 3.
        var result = Transcript.Merge(previous, 0, 3, new[] { 2 }, new[] { Msg(2) });
        Assert.NotNull(result);
        Assert.Equal(3, result!.Count);
        Assert.Equal("m2", result[2].Id);
    }

    [Fact]
    public void MergeReturnsNullWhenResultIsShortOfTotal()
    {
        var previous = new List<BridgeMessage> { Msg(0) };
        // total claims 3 but only indices 0..1 can be filled → short.
        var result = Transcript.Merge(previous, 0, 3, new[] { 1 }, new[] { Msg(1) });
        Assert.Null(result);
    }

    private static BridgeMessage Msg(int index) =>
        new("m" + index, "assistant", new[] { new MessagePart("text", "t" + index, null, null, null, null, null, null, null) }, null, null);
}
