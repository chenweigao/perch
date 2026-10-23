using System.Text.Json;
using System.Text.Json.Nodes;
using Perch.Core.Protocol;

namespace Perch.Core.Tests;

/// Reads the fixtures generated from the real bridge by
/// windows/tools/generate-fixtures.py. Every test that touches wire shapes goes through
/// here, so a bridge change shows up as a fixture regeneration + test diff rather than
/// a silently wrong hand-written expectation.
public static class Fixtures
{
    private static readonly string Directory = Locate();

    private static string Locate()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "fixtures");
            if (System.IO.Directory.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("找不到 fixtures 目录；请先运行 windows/tools/generate-fixtures.py。");
    }

    public static string Raw(string name) => File.ReadAllText(Path.Combine(Directory, name));

    public static T Read<T>(string name) => BridgeJson.Read<T>(Raw(name));

    public static JsonNode ReadNode(string name) =>
        JsonNode.Parse(Raw(name)) ?? throw new InvalidDataException(name + " 不是有效的 JSON。");

    /// Reads an `{status, body}` error envelope fixture.
    public static (int Status, string Body) ReadError(string name)
    {
        var node = ReadNode(name).AsObject();
        var status = node["status"]!.GetValue<int>();
        var body = node["body"]!.ToJsonString(BridgeJson.Options);
        return (status, body);
    }

    public static IReadOnlyList<string> Names =>
        System.IO.Directory.GetFiles(Directory, "*.json").Select(Path.GetFileName).OfType<string>().ToList();
}
