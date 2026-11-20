using System.ComponentModel;
using System.Runtime.InteropServices;
using NetworkMonitor.Core;

namespace NetworkMonitor.App.Native;

/// <summary>Passive interface counters from Windows IP Helper's GetIfTable2.</summary>
internal sealed class IpHelperSnapshotProvider
{
    private const int InterfaceStringLength = 257;
    private const int PhysicalAddressLength = 32;

    public IReadOnlyList<InterfaceSnapshot> Capture()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows IP Helper is only available on Windows.");
        var result = GetIfTable2(out var table);
        if (result != 0) throw new Win32Exception(unchecked((int)result), "GetIfTable2 failed.");

        try
        {
            var count = unchecked((uint)Marshal.ReadInt32(table));
            if (count > 4096) throw new InvalidDataException($"IP Helper returned an implausible interface count ({count}).");
            var rowOffset = IntPtr.Size == 8 ? 8 : 8; // MIB_IF_ROW2 is 8-byte aligned on supported x64/ARM64 targets.
            var rowSize = Marshal.SizeOf<MibIfRow2>();
            var capturedUtc = DateTimeOffset.UtcNow;
            var monotonic = System.Diagnostics.Stopwatch.GetTimestamp();
            var snapshots = new List<InterfaceSnapshot>((int)count);

            for (var i = 0; i < count; i++)
            {
                var rowPtr = IntPtr.Add(table, checked(rowOffset + (int)i * rowSize));
                var row = Marshal.PtrToStructure<MibIfRow2>(rowPtr);
                var kind = Classify(row);
                snapshots.Add(new InterfaceSnapshot(
                    row.InterfaceGuid,
                    row.InterfaceLuid,
                    row.InterfaceIndex,
                    NullIfEmpty(row.Alias),
                    NullIfEmpty(row.Description),
                    kind,
                    (row.InterfaceAndOperStatusFlags & 0x01) != 0,
                    row.OperStatus == 1,
                    row.MediaConnectState == 1 && (row.InterfaceAndOperStatusFlags & 0x10) == 0,
                    row.InOctets,
                    row.OutOctets,
                    capturedUtc,
                    monotonic));
            }
            return snapshots;
        }
        finally { FreeMibTable(table); }
    }

    private static InterfaceKind Classify(MibIfRow2 row)
    {
        if (row.Type == 24 || row.AccessType == 1) return InterfaceKind.Loopback;
        if (row.Type == 131 || row.TunnelType != 0 || row.MediaType == 15) return InterfaceKind.Tunnel;
        if (row.Type == 71 || row.PhysicalMediumType is 1 or 9 || row.MediaType == 16) return InterfaceKind.WiFi;
        if (row.PhysicalMediumType == 10) return InterfaceKind.Bluetooth;
        if (row.Type == 6 || row.PhysicalMediumType == 14 || row.MediaType == 0) return InterfaceKind.Ethernet;
        return InterfaceKind.Other;
    }

    private static string NullIfEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? "Unnamed interface" : value.TrimEnd('\0');

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint GetIfTable2(out IntPtr table);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern void FreeMibTable(IntPtr memory);

    // Mirrors the SDK MIB_IF_ROW2 layout. The status flags are an 8-bit bit field.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MibIfRow2
    {
        public ulong InterfaceLuid;
        public uint InterfaceIndex;
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = InterfaceStringLength)] public string Alias;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = InterfaceStringLength)] public string Description;
        public uint PhysicalAddressLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = PhysicalAddressLength, ArraySubType = UnmanagedType.U1)] public byte[] PhysicalAddress;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = PhysicalAddressLength, ArraySubType = UnmanagedType.U1)] public byte[] PermanentPhysicalAddress;
        public uint Mtu;
        public uint Type;
        public int TunnelType;
        public int MediaType;
        public uint PhysicalMediumType;
        public uint AccessType;
        public uint DirectionType;
        public byte InterfaceAndOperStatusFlags;
        public int OperStatus;
        public int AdminStatus;
        public int MediaConnectState;
        public Guid NetworkGuid;
        public int ConnectionType;
        public ulong TransmitLinkSpeed;
        public ulong ReceiveLinkSpeed;
        public ulong InOctets;
        public ulong InUcastPkts;
        public ulong InNUcastPkts;
        public ulong InDiscards;
        public ulong InErrors;
        public ulong InUnknownProtos;
        public ulong InUcastOctets;
        public ulong InMulticastOctets;
        public ulong InBroadcastOctets;
        public ulong OutOctets;
        public ulong OutUcastPkts;
        public ulong OutNUcastPkts;
        public ulong OutDiscards;
        public ulong OutErrors;
        public ulong OutUcastOctets;
        public ulong OutMulticastOctets;
        public ulong OutBroadcastOctets;
        public ulong OutQLen;
    }
}
