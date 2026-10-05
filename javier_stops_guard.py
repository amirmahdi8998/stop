"""Manage existing Javier positions only. Never opens positions; bound to the
account configured in javier_live.json (login 918850, LiteFinance live)."""
import argparse
import json
import logging
import math
import time
from datetime import datetime, timezone
from pathlib import Path

LOG = logging.getLogger("guard")

TRADE_MODE_NAMES = {
    'demo': 'ACCOUNT_TRADE_MODE_DEMO',
    'contest': 'ACCOUNT_TRADE_MODE_CONTEST',
    'real': 'ACCOUNT_TRADE_MODE_REAL',
    'live': 'ACCOUNT_TRADE_MODE_REAL',
}


def expected_trade_mode(mt5, cfg):
    """Map the config's trade_mode label (demo/live) to an MT5 trade-mode constant."""
    label = str(cfg.get('trade_mode', 'live')).strip().lower()
    if label not in TRADE_MODE_NAMES:
        raise ValueError('Unsupported trade_mode %r; expected one of: %s'
                         % (label, ', '.join(sorted(TRADE_MODE_NAMES))))
    return getattr(mt5, TRADE_MODE_NAMES[label])


def rounded(price, tick, digits, up):
    units = math.ceil(price / tick - 1e-8) if up else math.floor(price / tick + 1e-8)
    return round(units * tick, digits)


def atr_at_entry(rates, entry_time, period=14):
    """Simple mean of true ranges, using only M1 candles closed before entry."""
    bars = sorted((r for r in rates if int(r['time']) + 60 <= entry_time),
                  key=lambda r: int(r['time']))
    if len(bars) < period + 1:
        raise ValueError("Insufficient closed M1 candles before entry")
    bars = bars[-period - 1:]
    ranges = [max(float(b['high']) - float(b['low']),
                  abs(float(b['high']) - float(a['close'])),
                  abs(float(b['low']) - float(a['close'])))
              for a, b in zip(bars, bars[1:])]
    value = sum(ranges) / period
    if not math.isfinite(value) or value <= 0:
        raise ValueError("Invalid ATR")
    return value


class Guard:
    def __init__(self, mt5, cfg, apply=False):
        self.mt5, self.cfg, self.apply = mt5, cfg, apply
        self.distances = {}
        self.last_count = None
        self.quotes = {}

    def check_account(self, require_trading=True):
        account = self.mt5.account_info()
        terminal = self.mt5.terminal_info()
        if (account is None or terminal is None or not terminal.connected or
                account.login != self.cfg['account'] or
                account.trade_mode != expected_trade_mode(self.mt5, self.cfg) or
                account.server != self.cfg['server']):
            raise RuntimeError("Stopped: connected account/server/trade-mode does not match the configuration")
        if self.apply and require_trading and (not account.trade_allowed or not account.trade_expert or
                           not terminal.trade_allowed or terminal.tradeapi_disabled):
            raise RuntimeError("Stopped: terminal/account blocks Python trading")

    def entry_distances(self, p, info):
        key = (p.ticket, p.time, p.price_open, p.volume)
        if key in self.distances:
            return self.distances[key]
        rates = self.mt5.copy_rates_from(p.symbol, self.mt5.TIMEFRAME_M1,
                                        datetime.fromtimestamp(p.time, timezone.utc),
                                        self.cfg['atr_period'] + 2)
        if rates is None:
            raise ValueError(f"Cannot read candles: {self.mt5.last_error()}")
        atr = atr_at_entry(rates, p.time, self.cfg['atr_period'])
        buy = p.type == self.mt5.POSITION_TYPE_BUY
        one_tick_loss = self.mt5.order_calc_profit(
            self.mt5.ORDER_TYPE_BUY if buy else self.mt5.ORDER_TYPE_SELL,
            p.symbol, p.volume, p.price_open,
            p.price_open + (-1 if buy else 1) * info.trade_tick_size)
        if one_tick_loss is None or not math.isfinite(one_tick_loss) or one_tick_loss >= 0:
            raise ValueError("Cannot calculate per-tick loss in account currency")
        cap = math.floor(self.cfg['max_loss_money'] / abs(one_tick_loss) + 1e-8) * info.trade_tick_size
        stop = min(atr * self.cfg['atr_stop_multiple'], cap)
        target = atr * self.cfg['atr_target_multiple']
        if stop <= 0 or target <= 0:
            raise ValueError("Risk cap is smaller than one tick")
        self.distances[key] = (stop, target)
        return stop, target

    def protect(self, p):
        if p.symbol != self.cfg['symbol'] or p.magic != self.cfg['magic']:
            return
        if p.sl > 0 and p.tp > 0:
            return
        info = self.mt5.symbol_info(p.symbol)
        quote = self.mt5.symbol_info_tick(p.symbol)
        if info is None or quote is None or info.point <= 0 or info.trade_tick_size <= 0:
            raise ValueError("Missing symbol information")
        # MQL5 order_mode flags are not exported by the Python MT5 package.
        if not (info.order_mode & 16 and info.order_mode & 32):
            raise ValueError("Symbol does not support SL and TP")
        if min(quote.bid, quote.ask) <= 0:
            raise ValueError("Missing or stale quote")
        # Broker timestamps can use server time. Measure updates locally instead.
        stamp = getattr(quote, 'time_msc', quote.time * 1000)
        observed = self.quotes.get(p.symbol)
        if observed is None:
            self.quotes[p.symbol] = (stamp, time.monotonic(), False)
            raise ValueError('Waiting for a fresh tick after startup')
        previous, received, confirmed = observed
        if stamp != previous:
            received, confirmed = time.monotonic(), True
            self.quotes[p.symbol] = (stamp, received, confirmed)
        if not confirmed or time.monotonic() - received > 30:
            raise ValueError('Waiting for fresh tick; quote has not updated')
        stop, target = self.entry_distances(p, info)
        buy = p.type == self.mt5.POSITION_TYPE_BUY
        current = quote.bid if buy else quote.ask
        freeze = info.trade_freeze_level * info.point
        if freeze > 0 and any(v > 0 and abs(current - v) <= freeze for v in (p.sl, p.tp)):
            raise ValueError("Existing level is frozen")
        sl = p.sl or rounded(p.price_open + (-stop if buy else stop),
                             info.trade_tick_size, info.digits, not buy)
        tp = p.tp or rounded(p.price_open + (target if buy else -target),
                             info.trade_tick_size, info.digits, buy)
        minimum = max(info.trade_stops_level * info.point, freeze) + info.trade_tick_size
        if sl != p.sl and (current - sl if buy else sl - current) < minimum - 1e-8:
            LOG.warning("%s SL deferred: crossed price or broker minimum", p.ticket)
            sl = p.sl
        if tp != p.tp and (tp - current if buy else current - tp) < minimum - 1e-8:
            LOG.warning("%s TP deferred: crossed price or broker minimum", p.ticket)
            tp = p.tp
        if sl == p.sl and tp == p.tp:
            return
        if not self.apply:
            LOG.info("DRY RUN ticket=%s SL=%s TP=%s", p.ticket, sl, tp)
            return
        self.check_account()
        # Re-read before modifying: another EA or the user may have changed levels.
        fresh = self.mt5.positions_get(ticket=p.ticket)
        if not fresh or (fresh[0].symbol, fresh[0].magic, fresh[0].sl, fresh[0].tp,
                         fresh[0].price_open, fresh[0].volume) != (
                p.symbol, p.magic, p.sl, p.tp, p.price_open, p.volume):
            return
        request = dict(action=self.mt5.TRADE_ACTION_SLTP, symbol=p.symbol,
                       position=p.ticket, magic=p.magic, sl=sl, tp=tp)
        checked = self.mt5.order_check(request)
        if checked is None or checked.retcode != 0:
            raise ValueError(f"order_check rejected: {checked}; {self.mt5.last_error()}")
        self.check_account()
        result = self.mt5.order_send(request)
        if result is None or result.retcode not in (
                self.mt5.TRADE_RETCODE_DONE, self.mt5.TRADE_RETCODE_NO_CHANGES):
            raise ValueError(f"order_send rejected: {result}; {self.mt5.last_error()}")
        actual = self.mt5.positions_get(ticket=p.ticket)
        verified = bool(actual and abs(actual[0].sl - sl) < info.trade_tick_size / 2 and
                        abs(actual[0].tp - tp) < info.trade_tick_size / 2)
        LOG.info("ticket=%s SL=%s TP=%s verified=%s", p.ticket, sl, tp, verified)

    def sweep(self):
        self.check_account()
        positions = self.mt5.positions_get(symbol=self.cfg['symbol'])
        if positions is None:
            raise RuntimeError(f"Cannot read positions: {self.mt5.last_error()}")
        matched = [p for p in positions if p.magic == self.cfg['magic']]
        if len(matched) != self.last_count:
            LOG.info('Matching Javier positions=%s', len(matched))
            self.last_count = len(matched)
        for p in positions:
            try:
                self.protect(p)
            except ValueError as exc:
                LOG.warning("ticket=%s %s", p.ticket, exc)
        active = {p.ticket for p in positions}
        self.distances = {k: v for k, v in self.distances.items() if k[0] in active}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path(__file__).with_name('javier_live.json'))
    parser.add_argument('--apply', action='store_true', help='Enable SL/TP writes on the bound account only')
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    cfg = json.loads(args.config.read_text(encoding='utf-8'))
    for key in ('max_loss_money', 'atr_stop_multiple', 'atr_target_multiple', 'interval_seconds'):
        if not math.isfinite(cfg[key]) or cfg[key] <= 0:
            parser.error(f'{key} must be positive and finite')
    if cfg['account'] <= 0 or cfg['magic'] <= 0 or cfg['atr_period'] < 1:
        parser.error('Invalid account, magic or ATR period')
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                        handlers=[logging.StreamHandler(), logging.FileHandler(
                            Path(__file__).with_name('javier_python_guard.log'), encoding='utf-8')])
    import MetaTrader5 as mt5
    if not mt5.initialize(cfg['terminal_path']):
        raise RuntimeError(f'MT5 initialization failed: {mt5.last_error()}')
    try:
        guard = Guard(mt5, cfg, args.apply)
        LOG.info('Starting mode=%s bound_account=%s', 'APPLY' if args.apply else 'DRY RUN', cfg['account'])
        while True:
            guard.sweep()
            if args.once:
                break
            time.sleep(cfg['interval_seconds'])
    finally:
        mt5.shutdown()


if __name__ == '__main__':
    main()
