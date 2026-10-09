using Ical.Net;
using Ical.Net.DataTypes;
using Ical.Net.CalendarComponents;

namespace Boring.Core;
public sealed record AgendaEvent(string Title, DateTimeOffset Start, DateTimeOffset End, string Location, string Description);
public static class CalendarService
{
    public static List<AgendaEvent> Read(string path, DateTimeOffset now)
    {
        var calendar = Calendar.Load(File.ReadAllText(path));
        var start = now.LocalDateTime.Date;
        return calendar.GetOccurrences(new CalDateTime(start), new CalDateTime(start.AddDays(14)))
            .Where(o => o.Source is CalendarEvent)
            .Select(o => new AgendaEvent(((CalendarEvent)o.Source).Summary ?? "Untitled event", new DateTimeOffset(o.Period.StartTime.AsSystemLocal),
                new DateTimeOffset(o.Period.EndTime?.AsSystemLocal ?? o.Period.StartTime.AsSystemLocal), ((CalendarEvent)o.Source).Location ?? "", ((CalendarEvent)o.Source).Description ?? ""))
            .Where(e => e.End >= now).OrderBy(e => e.Start).Take(100).ToList();
    }
}
