using Perch.Core.Protocol;

namespace Perch.Core.State;

/// Holds one session's transcript and merges delta snapshots into it.
///
/// The bridge streams by *replacing* message positions, not by appending text: a
/// streaming reply arrives as a full message body at its index on every tick, and a
/// delta names only the indices that changed. Merging by index is what prevents the
/// classic bugs this MVP must avoid — re-appending the growing reply each poll, and
/// letting a late response for an old session overwrite the newly selected one.
///
/// Port of NativeHistoryWindow.merge / NativeAgentSnapshot.applying in
/// Sources/WorkbenchCore/NativeAgentProtocol.swift, against the real bridge fixtures.
public sealed class Transcript
{
    /// Messages from absolute index `Start`, so position `Start + i` is `Messages[i]`.
    public IReadOnlyList<BridgeMessage> Messages { get; private set; } = Array.Empty<BridgeMessage>();
    public string? Epoch { get; private set; }
    public int Start { get; private set; }
    public int Total { get; private set; }
    public long Revision { get; private set; }
    public string? SessionId { get; private set; }
    public bool HasOlder => Start > 0;

    /// A full (paged) snapshot replaces the transcript wholesale.
    public static Transcript FromFull(BridgeSnapshot snapshot)
    {
        var transcript = new Transcript
        {
            SessionId = snapshot.Id,
            Messages = snapshot.MessagesOrEmpty,
            Revision = snapshot.Revision,
        };
        if (snapshot.History is { } window)
        {
            transcript.Epoch = window.Epoch;
            transcript.Start = window.Start;
            transcript.Total = window.Total;
        }
        else
        {
            // Legacy/unpaged snapshot: no window, the messages are the whole history.
            transcript.Start = 0;
            transcript.Total = snapshot.MessagesOrEmpty.Count;
        }
        return transcript;
    }

    /// Applies a delta response onto the current transcript. Returns false (and leaves
    /// the transcript untouched) when the delta does not belong to this history: a
    /// different session, a replaced epoch, or a base revision that is not exactly the
    /// one this transcript is at. The caller then re-reads the full page.
    public bool TryApplyDelta(BridgeSnapshot snapshot, out bool needsFullRead)
    {
        needsFullRead = false;
        if (snapshot.Id != SessionId) return false;
        var window = snapshot.History;
        var indices = window?.Indices;
        if (window is null || indices is null)
        {
            // Not a delta; treat as a full replacement so the caller can refresh.
            ReplaceFromFull(snapshot);
            return true;
        }
        if (window.Epoch != Epoch)
        {
            // History was replaced on the bridge (a restart or a compaction). The
            // positions we hold are meaningless; force a full re-read.
            needsFullRead = true;
            return false;
        }
        if (window.BaseRevision is not { } baseRevision || baseRevision != Revision)
        {
            // We missed a tick or are behind; a full read reconciles without dropping
            // or duplicating anything.
            needsFullRead = true;
            return false;
        }
        if (window.Start != Start)
        {
            // The window moved (an older page expanded it) while this delta was in
            // flight. Do not merge across mismatched starts; re-read.
            needsFullRead = true;
            return false;
        }

        var messages = snapshot.MessagesOrEmpty;
        if (indices.Count != messages.Count)
        {
            needsFullRead = true;
            return false;
        }

        var merged = Merge(Messages, Start, window.Total, indices, messages);
        if (merged is null)
        {
            needsFullRead = true;
            return false;
        }

        Messages = merged;
        Total = window.Total;
        Revision = snapshot.Revision;
        return true;
    }

    private void ReplaceFromFull(BridgeSnapshot snapshot)
    {
        var replaced = FromFull(snapshot);
        Messages = replaced.Messages;
        Epoch = replaced.Epoch;
        Start = replaced.Start;
        Total = replaced.Total;
        Revision = replaced.Revision;
        SessionId = replaced.SessionId;
    }

    /// Merges changed positions into the window held from absolute index `start`.
    /// `previous` is the messages already held for that window; `changes` must be in
    /// ascending index order, and each index either replaces an existing slot or
    /// appends exactly at the end. The result must fill [start, total) completely.
    /// Returns null on any inconsistency so the caller re-reads rather than showing a
    /// truncated or duplicated transcript.
    internal static IReadOnlyList<BridgeMessage>? Merge(IReadOnlyList<BridgeMessage> previous, int start, int total,
        IReadOnlyList<int> indices, IReadOnlyList<BridgeMessage> changes)
    {
        if (total < start) return null;
        var target = total - start;
        // Retain what we already hold for this window, cut to the new total.
        var combined = new List<BridgeMessage>(Math.Min(previous.Count, target));
        for (var i = 0; i < previous.Count && i < target; i++) combined.Add(previous[i]);

        var last = start - 1;
        for (var i = 0; i < indices.Count; i++)
        {
            var index = indices[i];
            if (index <= last) return null;       // not strictly ascending
            if (index < start) return null;       // before the held window
            if (index >= total) return null;      // past the transcript end
            var offset = index - start;
            if (offset > combined.Count) return null; // a gap we cannot fill
            if (offset == combined.Count) combined.Add(changes[i]);
            else combined[offset] = changes[i];
            last = index;
        }
        // A delta must fully describe [start, total); a short result means positions
        // are missing and the caller must re-read.
        if (combined.Count != target) return null;
        return combined;
    }
}
