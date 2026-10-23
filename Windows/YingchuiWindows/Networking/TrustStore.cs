using System.Text.Json;

namespace YingchuiWindows.Networking;

public sealed record TrustedMac(string SessionToken, string CertificateSha256);

public sealed class TrustStore
{
    private readonly string _path;
    private Dictionary<string, TrustedMac> _items;

    public TrustStore()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YingchuiInterconnect");
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "trusted-macs.json");
        try
        {
            _items = File.Exists(_path)
                ? JsonSerializer.Deserialize<Dictionary<string, TrustedMac>>(File.ReadAllText(_path)) ?? []
                : [];
        }
        catch
        {
            _items = [];
        }
    }

    public TrustedMac? Get(string key) => _items.GetValueOrDefault(key);

    public void Save(string key, TrustedMac value)
    {
        _items[key] = value;
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(_items, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, _path, true);
    }

    public void Remove(string key)
    {
        if (!_items.Remove(key)) return;
        File.WriteAllText(_path, JsonSerializer.Serialize(_items, new JsonSerializerOptions { WriteIndented = true }));
    }
}
