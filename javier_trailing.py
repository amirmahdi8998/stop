"""Demo-only trailing prototype inferred from observations, not Javier source."""
import argparse
import json
import logging
import math
import time
from contextlib import contextmanager
from pathlib import Path
from javier_stops_guard import Guard, rounded, LOG


@contextmanager
def single_instance():
    """Windows mutex prevents duplicate managers, including double-click launches."""
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.ReleaseMutex.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateMutexW(None, True, 'Local\\CodexJavierTrailingManager')
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    exists = ctypes.get_last_error() == 183
    try:
        if exists:
            print('Trailing manager is already running. No duplicate was started.', flush=True)
        yield not exists
    finally:
        if not exists:
            kernel.ReleaseMutex(handle)
        kernel.CloseHandle(handle)


def trailing_level(buy, entry, current, old_sl, point, tick, digits,
                   distance_points=20, lock_points=5, minimum=0):
    proposed = rounded(current + (-1 if buy else 1) * distance_points * point,
                       tick, digits, buy)
    # Round toward the market, keeping at least the requested profit lock.
    gain = (proposed - entry) * (1 if buy else -1)
    if gain < lock_points * point - 1e-8:
        return old_sl
    if old_sl and (proposed <= old_sl if buy else proposed >= old_sl):
        return old_sl
    if (current - proposed if buy else proposed - current) < minimum - 1e-8:
        return old_sl
    return proposed


class TrailingGuard(Guard):
    def protect(self, p):
        m = self.mt5
        if p.symbol != self.cfg['symbol'] or p.magic != self.cfg['magic']:
            return
        info, quote = m.symbol_info(p.symbol), m.symbol_info_tick(p.symbol)
        if info is None or quote is None or min(quote.bid, quote.ask) <= 0:
            raise ValueError('Missing quote or symbol')
        if info.point <= 0 or info.trade_tick_size <= 0 or not info.order_mode & 16:
            raise ValueError('Symbol cannot accept SL')
        stamp = getattr(quote, 'time_msc', quote.time * 1000)
        previous = self.quotes.get(p.symbol)
        now = time.monotonic()
        if previous is None:
            self.quotes[p.symbol] = (stamp, now, False)
            return
        last, received, confirmed = previous
        if stamp != last:
            received, confirmed = now, True
            self.quotes[p.symbol] = (stamp, received, confirmed)
        if not confirmed or now - received > 30:
            return
        buy = p.type == m.POSITION_TYPE_BUY
        current = quote.bid if buy else quote.ask
        freeze = info.trade_freeze_level * info.point
        if freeze and any(v > 0 and abs(current - v) <= freeze for v in (p.sl, p.tp)):
            return
        sl = trailing_level(buy, p.price_open, current, p.sl, info.point,
                            info.trade_tick_size, info.digits,
                            self.cfg['distance_points'], self.cfg['lock_points'],
                            max(info.trade_stops_level * info.point, freeze) + info.trade_tick_size)
        if sl == p.sl:
            return
        if not self.apply:
            LOG.info('PREVIEW ticket=%s oldSL=%s proposedSL=%s TP preserved=%s',
                     p.ticket, p.sl, sl, p.tp)
            return
        self.check_account()
        fresh = m.positions_get(ticket=p.ticket)
        if not fresh or any(getattr(fresh[0], k) != getattr(p, k)
                            for k in ('symbol', 'magic', 'type', 'price_open', 'volume', 'sl', 'tp')):
            return
        request = dict(action=m.TRADE_ACTION_SLTP, position=p.ticket,
                       symbol=p.symbol, magic=p.magic, sl=sl, tp=p.tp)
        check = m.order_check(request)
        if check is None or check.retcode != 0:
            raise ValueError(f'Check failed: {check}')
        self.check_account()
        result = m.order_send(request)
        if result is None or result.retcode not in (m.TRADE_RETCODE_DONE, m.TRADE_RETCODE_NO_CHANGES):
            raise ValueError(f'Send failed: {result}')
        actual = m.positions_get(ticket=p.ticket)
        verified = bool(actual and abs(actual[0].sl - sl) < info.trade_tick_size / 2 and
                        abs(actual[0].tp - p.tp) < info.trade_tick_size / 2)
        LOG.info('ticket=%s SL=%s TP=%s verified=%s', p.ticket, sl, p.tp, verified)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    cfg = json.loads(Path(__file__).with_name('javier_trailing_demo.json').read_text())
    interval = cfg.get('interval_seconds', .5)
    if not math.isfinite(interval) or interval < .05:
        parser.error('Polling interval must be finite and at least 0.05 seconds')
    if cfg['distance_points'] <= 0 or cfg['lock_points'] <= 0:
        parser.error('Distances must be positive')
    import MetaTrader5 as m
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s',
                        handlers=[logging.StreamHandler(), logging.FileHandler(
                            Path(__file__).with_name('javier_trailing.log'), encoding='utf-8')])
    if not m.initialize(cfg['terminal_path']):
        raise RuntimeError(m.last_error())
    try:
        guard = TrailingGuard(m, cfg, args.apply)
        LOG.info('Inferred trailing prototype; mode=%s', 'APPLY' if args.apply else 'PREVIEW')
        waiting = False
        disconnected = False
        while True:
            # Remain ready while the user attaches/enables the EA. Account binding
            # is still checked while idle and immediately before every write.
            account, terminal = m.account_info(), m.terminal_info()
            if account is None or terminal is None or not terminal.connected:
                if not disconnected:
                    LOG.warning('Connection unavailable; writes paused until reconnection')
                disconnected = True
                time.sleep(.5)
                continue
            if disconnected:
                LOG.info('Connection restored; rechecking bound demo')
                disconnected = False
            # Wrong account/server still stops immediately; no automatic rebinding.
            if (account.login != cfg['account'] or account.server != cfg['server'] or
                    account.trade_mode != m.ACCOUNT_TRADE_MODE_DEMO):
                raise RuntimeError('Stopped: account/server is not the configured demo')
            allowed = bool(account and terminal and account.trade_allowed and
                           account.trade_expert and terminal.trade_allowed and
                           not terminal.tradeapi_disabled)
            if args.apply and not allowed:
                if not waiting:
                    LOG.info('READY demo=%s; waiting for Algo Trading permission', cfg['account'])
                waiting = True
                time.sleep(.5)
                continue
            if waiting:
                LOG.info('Algo Trading enabled; stop management active')
                waiting = False
            try:
                guard.sweep()
            except RuntimeError:
                # A disconnect or permission change can occur between snapshots.
                # Retry only when disconnected, or still on the exact bound demo.
                current_account, current_terminal = m.account_info(), m.terminal_info()
                if (current_account is not None and current_terminal is not None and
                        current_terminal.connected and
                        (current_account.login != cfg['account'] or
                         current_account.server != cfg['server'] or
                         current_account.trade_mode != m.ACCOUNT_TRADE_MODE_DEMO)):
                    raise
                LOG.warning('Temporary connection/permission failure; retrying safely')
                time.sleep(.5)
                continue
            time.sleep(interval)
    finally:
        m.shutdown()


if __name__ == '__main__':
    with single_instance() as acquired:
        if acquired:
            main()
