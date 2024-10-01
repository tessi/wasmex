function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
};

export const init = async () => {
  console.log('hi parker');
  const response = await fetch('https://launchscout.com');
  const text = await response.text();
  console.log(text);
  const thing = await sleep(3000);
  return ["other", "stuff", "man"];
};
export const addTodo = (item, list) => list.concat([item, ...list]);