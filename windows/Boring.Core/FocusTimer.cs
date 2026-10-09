namespace Boring.Core;
public sealed record FocusSnapshot(DateTimeOffset? Deadline, double RemainingSeconds);

public sealed class FocusTimer
{
    private readonly TimeProvider time;
    private DateTimeOffset? deadline;
    private TimeSpan remaining;
    public FocusTimer(TimeProvider? clock = null) => time = clock ?? TimeProvider.System;
    public bool Running => deadline.HasValue;
    public bool Paused => !Running && remaining > TimeSpan.Zero;
    public TimeSpan Remaining => deadline is { } end ? Max(end - time.GetUtcNow()) : remaining;
    public event Action? Completed;
    public FocusSnapshot Snapshot() => new(deadline, Remaining.TotalSeconds);
    public void Restore(FocusSnapshot? snapshot) {
        if (snapshot == null || !double.IsFinite(snapshot.RemainingSeconds) || snapshot.RemainingSeconds < 0 || snapshot.RemainingSeconds > 86400) return;
        deadline = snapshot.Deadline; remaining = TimeSpan.FromSeconds(snapshot.RemainingSeconds);
    }
    public void Start(TimeSpan duration) {
        if (duration <= TimeSpan.Zero || duration > TimeSpan.FromHours(24)) throw new ArgumentOutOfRangeException(nameof(duration));
        remaining = duration; deadline = time.GetUtcNow() + duration;
    }
    public void Pause() { remaining = Remaining; deadline = null; }
    public void Resume() { if (Paused) deadline = time.GetUtcNow() + remaining; }
    public void Reset() { deadline = null; remaining = TimeSpan.Zero; }
    public void Tick() { if (Running && Remaining == TimeSpan.Zero) { Reset(); Completed?.Invoke(); } }
    private static TimeSpan Max(TimeSpan value) => value < TimeSpan.Zero ? TimeSpan.Zero : value;
}
