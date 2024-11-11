export function greet(who) {
  return `Hello, ${who}!`;
}

export function multiGreet(who, times) {
  var results = [];
  for(let i = 0; i < times; i++) {
    results.push(greet(who));
  }
  return results;
}