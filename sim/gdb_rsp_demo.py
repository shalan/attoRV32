#!/usr/bin/env python3
"""gdb_rsp_demo.py — Scripted GDB RSP demo against the Verilator bridge.

Connects to localhost:3333, sends RSP packets, and prints the exchange.
Demonstrates: halt, register read, memory read, memory write, continue.
"""

import socket, struct, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3333

def rsp_checksum(data: bytes) -> int:
    return sum(data) & 0xFF

def send_packet(sock, payload: str):
    data = payload.encode()
    ck = rsp_checksum(data)
    pkt = b'$' + data + b'#' + f'{ck:02x}'.encode()
    sock.sendall(pkt)
    print(f'  → ${payload}#...')

def recv_packet(sock, timeout=5.0) -> str:
    """Receive one RSP packet, stripping ACK/NAK and framing."""
    sock.settimeout(timeout)
    buf = b''
    try:
        while True:
            b = sock.recv(1)
            if not b:
                return ''
            buf += b
            # Skip ACK bytes
            if buf == b'+':
                buf = b''
                continue
            # Look for complete packet
            if b'$' in buf and b'#' in buf:
                # Need 2 more chars for checksum
                rest = buf.split(b'#', 1)[1]
                while len(rest) < 2:
                    rest += sock.recv(1)
                # Extract payload
                start = buf.index(b'$')
                end = buf.index(b'#')
                payload = buf[start+1:end].decode(errors='replace')
                # Send ACK
                sock.sendall(b'+')
                return payload
    except socket.timeout:
        return '<timeout>'

def hex_le_to_u32(h: str) -> int:
    """Parse 8 hex chars as little-endian 32-bit."""
    bs = bytes.fromhex(h)
    return struct.unpack('<I', bs)[0]

def main():
    print(f'Connecting to localhost:{PORT} ...')
    sock = socket.create_connection(('localhost', PORT), timeout=5)
    print('Connected.\n')

    # The stub sends T05 immediately on halt.
    print('=== Waiting for initial stop-reply ===')
    reply = recv_packet(sock)
    print(f'  ← {reply}')
    assert reply.startswith('T05'), f'Expected T05, got {reply}'
    print('  ✓ CPU halted (UART break / initial trap)\n')

    # ? — query stop reason
    print('=== ? (stop reason) ===')
    send_packet(sock, '?')
    reply = recv_packet(sock)
    print(f'  ← {reply}')
    assert reply == 'T05'
    print('  ✓ Stop reason: SIGTRAP\n')

    # g — read all registers
    print('=== g (read registers) ===')
    send_packet(sock, 'g')
    reply = recv_packet(sock)
    nregs = len(reply) // 8
    print(f'  ← ({len(reply)} hex chars = {nregs} registers)')
    # Decode a few interesting registers
    regs = {}
    names = ['zero','ra','sp','gp','tp','t0','t1','t2',
             's0','s1','a0','a1','a2','a3','a4','a5',
             'a6','a7','s2','s3','s4','s5','s6','s7',
             's8','s9','s10','s11','t3','t4','t5','t6','pc']
    for i in range(min(nregs, 33)):
        val = hex_le_to_u32(reply[i*8:(i+1)*8])
        regs[names[i] if i < len(names) else f'x{i}'] = val
    for name in ['sp', 'a0', 'a4', 'a5', 'pc']:
        if name in regs:
            print(f'    {name:4s} = 0x{regs[name]:08X}')
    print(f'  ✓ {nregs} registers read\n')

    # m — read memory at 0x8 (the counter)
    print('=== m0008,04 (read counter at 0x8) ===')
    send_packet(sock, 'm0008,04')
    reply = recv_packet(sock)
    counter = hex_le_to_u32(reply)
    print(f'  ← {reply}  (= 0x{counter:08X} = {counter})')
    print(f'  ✓ Counter value: {counter}\n')

    # M — write memory: set counter to 0x1000
    print('=== M0008,04:00100000 (write counter = 0x1000) ===')
    send_packet(sock, 'M0008,04:00100000')
    reply = recv_packet(sock)
    print(f'  ← {reply}')
    assert reply == 'OK'
    print('  ✓ Memory written\n')

    # Verify the write
    print('=== m0008,04 (verify write) ===')
    send_packet(sock, 'm0008,04')
    reply = recv_packet(sock)
    counter = hex_le_to_u32(reply)
    print(f'  ← {reply}  (= 0x{counter:08X})')
    assert counter == 0x1000, f'Expected 0x1000, got 0x{counter:X}'
    print('  ✓ Verified: counter = 0x1000\n')

    # c — continue execution
    print('=== c (continue) ===')
    send_packet(sock, 'c')
    # The CPU resumes. We need to trigger another halt to see it stop.
    # Send a break character (0x03 = Ctrl-C in RSP) after a short pause.
    print('  (letting CPU run for 0.5s ...)')
    time.sleep(0.5)

    # Send Ctrl-C (0x03) to request halt
    print('  Sending Ctrl-C (0x03) to halt ...')
    sock.sendall(b'\x03')

    # Wait for stop reply
    reply = recv_packet(sock, timeout=5)
    print(f'  ← {reply}')
    if reply.startswith('T') or reply.startswith('S'):
        print('  ✓ CPU halted after continue\n')
    else:
        print(f'  ⚠ Unexpected reply (may need UART break instead of 0x03)\n')

    # Read counter again — should have incremented past 0x1000
    print('=== m0008,04 (read counter after run) ===')
    send_packet(sock, 'm0008,04')
    reply = recv_packet(sock)
    counter2 = hex_le_to_u32(reply)
    print(f'  ← {reply}  (= 0x{counter2:08X} = {counter2})')
    if counter2 > 0x1000:
        print(f'  ✓ Counter incremented: 0x1000 → 0x{counter2:X} (+{counter2 - 0x1000})\n')
    else:
        print(f'  ⚠ Counter did not advance (Ctrl-C halt may not work in sim)\n')

    # Read PC
    print('=== g (read PC after run) ===')
    send_packet(sock, 'g')
    reply = recv_packet(sock)
    if len(reply) >= 264:
        pc = hex_le_to_u32(reply[32*8:33*8])
        print(f'  PC = 0x{pc:08X}')
        if 0x0000 <= pc <= 0x0020:
            print('  ✓ PC is in user code\n')
        elif 0x1000 <= pc <= 0x1FFF:
            print('  ✓ PC is in ROM stub\n')

    print('=== Demo complete ===')
    sock.close()

if __name__ == '__main__':
    main()
