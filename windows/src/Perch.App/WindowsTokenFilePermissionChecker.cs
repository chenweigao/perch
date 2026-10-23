using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using Perch.Core.Secrets;

namespace Perch.App;

/// Windows implementation of the token-file permission audit: reads the file's DACL and
/// reports whether any group other than the owner can read it. A token file readable by
/// Everyone/Users/Authenticated Users is refused before it is ever opened.
public sealed class WindowsTokenFilePermissionChecker : ITokenFilePermissionChecker
{
    // Well-known SIDs that mean "more than just this user".
    private static readonly string[] BroadReadSids =
    {
        "S-1-1-0",     // Everyone
        "S-1-5-32-545", // Users
        "S-1-5-11",    // Authenticated Users
        "S-1-5-32-544", // Administrators (a shared admin group is still broader than one user)
    };

    public TokenFilePermission Audit(string path)
    {
        if (!File.Exists(path))
            return TokenFilePermission.Safe("文件尚不存在");
        try
        {
            var info = new FileInfo(path);
            var acl = info.GetAccessControl(AccessControlSections.Access);
            var owner = acl.GetOwner(typeof(SecurityIdentifier))?.Value;
            foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow) continue;
                if (!GrantsRead(rule.FileSystemRights)) continue;
                var sid = rule.IdentityReference as SecurityIdentifier;
                if (sid is null) continue;
                if (sid.Value == owner) continue; // the owner reading their own file is fine
                if (BroadReadSids.Contains(sid.Value))
                    return TokenFilePermission.Unsafe(SidName(sid.Value) + " 有读取权限");
            }
            return TokenFilePermission.Safe("仅文件所有者可读");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SystemException)
        {
            // If we cannot read the ACL we cannot prove it is safe; refuse.
            return TokenFilePermission.Unsafe("无法读取文件权限：" + ex.Message);
        }
    }

    private static bool GrantsRead(FileSystemRights rights) =>
        (rights & (FileSystemRights.Read | FileSystemRights.ReadData | FileSystemRights.FullControl)) != 0;

    private static string SidName(string sid) => sid switch
    {
        "S-1-1-0" => "Everyone",
        "S-1-5-32-545" => "Users",
        "S-1-5-11" => "Authenticated Users",
        "S-1-5-32-544" => "Administrators",
        _ => sid,
    };
}
