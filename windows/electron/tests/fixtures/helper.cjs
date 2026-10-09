const { createInterface } = require('node:readline');
process.stdout.write('{"event":"ready","data":');
setTimeout(() => process.stdout.write('true}\n'), 10);
createInterface({ input: process.stdin }).on('line', line => {
  const { id, method, args } = JSON.parse(line);
  if (method === 'exit') { process.exit(2); return; }
  if (method === 'bad') process.stdout.write('not-json\n');
  setTimeout(() => process.stdout.write(JSON.stringify({ id, result: args, error: method === 'error' ? 'Device unavailable' : null }) + '\n'), args.delay || 0);
});
