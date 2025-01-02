export async function getTime() {
  const response = await fetch('http://worldtimeapi.org/api/timezone/America/New_York');
  const result = await response.json();
  console.log(result);
  return result['utc_datetime'];
}
