namespace Boring.Core;
public readonly record struct IslandBounds(double X, double Y, double Width, double Height);
/// <summary>Interruptible, time-based geometry interpolation; no work when idle.</summary>
public sealed class IslandMotion
{
    private IslandBounds start, target;
    private double began, duration;
    public bool Active { get; private set; }
    public IslandBounds Current { get; private set; }
    public IslandBounds Begin(IslandBounds from, IslandBounds to, double seconds, double now) {
        start = Active ? Sample(now) : from; target = to; began = now; duration = Math.Max(.001, seconds); Active = true;
        Current = start; return start;
    }
    public IslandBounds Sample(double now) {
        if (!Active) return Current;
        var t = Math.Clamp((now - began) / duration, 0, 1);
        var eased = 1 - Math.Pow(1 - t, 3);
        static double Mix(double a, double b, double amount) => a + (b - a) * amount;
        Current = new(Mix(start.X, target.X, eased), Mix(start.Y, target.Y, eased), Mix(start.Width, target.Width, eased), Mix(start.Height, target.Height, eased));
        if (t == 1) Active = false; return Current;
    }
    public void Stop(IslandBounds bounds) { Current = bounds; Active = false; }
}
