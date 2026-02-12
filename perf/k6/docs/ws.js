import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { buildOptions } from '../common/thresholds.js';

export const options = Object.assign({}, buildOptions('docs'), {
  vus: 5,
  duration: '2m',
});

const YWS = __ENV.YPROVIDER_WS_URL || '';

export default function () {
  if (!YWS) {
    sleep(1);
    return;
  }
  const res = ws.connect(YWS, {}, function (socket) {
    socket.on('open', function () {
      socket.send('ping');
    });
    socket.on('message', function () {
      socket.close();
    });
    socket.setTimeout(function () {
      socket.close();
    }, 2000);
  });
  check(res, { 'ws status 101': (r) => r && r.status === 101 });
}



