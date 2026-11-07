import * as os from 'os'
import axios, { AxiosResponse } from 'axios'

// Physical network interfaces: classic names (eth0, wlan0) and predictable names used on
// x86 and newer OS releases (enp0s25, eno1, end0, wlp2s0...). Excludes balena/docker virtual
// interfaces (balena0, supervisor0, resin-vpn, br-*, veth*...)
const PHYSICAL_INTERFACE = /^(eth|wlan|en|wl)/

export function getIPAddresses(): string[] {
  let networkInterfaces: object = os.networkInterfaces()
  let addresses: string[] = Object.keys(networkInterfaces)
    .filter(i => PHYSICAL_INTERFACE.test(i))
    .map(i => networkInterfaces[i])
    .flat()
    .filter(i => !i.internal && i.family === 'IPv4')
    .map(i => i.address)

  return addresses
}

export function getIPAddress(): string | null {
  return getIPAddresses()[0] ?? null
}

export function restartBalenaService(service: string): Promise<AxiosResponse<any> | undefined> {
  return executeBalenaServiceAction(service, 'restart')

}

export function startBalenaService(service: string): Promise<AxiosResponse<any> | undefined> {
  return executeBalenaServiceAction(service, 'start')
}

export function stopBalenaService(service: string): Promise<AxiosResponse<any> | undefined> {
  return executeBalenaServiceAction(service, 'stop')
}

// Errors are logged rather than rejected: callers fire these without awaiting, and an
// unhandled rejection (e.g. service not present in the fleet) would otherwise go unreported or crash newer Node versions
function executeBalenaServiceAction (service: string, action: string): Promise<AxiosResponse<any> | undefined> {
  let url: string = `${process.env.BALENA_SUPERVISOR_ADDRESS}/v2/applications/${process.env.BALENA_APP_ID}/${action}-service?apikey=${process.env.BALENA_SUPERVISOR_API_KEY}`
  return axios.post(url, { serviceName: service })
    .catch(error => {
      console.log(`Error trying to ${action} service '${service}': ${error.message}`)
      return undefined
    })
}

export function rebootDevice ():Promise<AxiosResponse<any>> {
  return axios.post(`${process.env.BALENA_SUPERVISOR_ADDRESS}/v1/reboot?apikey=${process.env.BALENA_SUPERVISOR_API_KEY}`)
}

export function shutdownDevice ():Promise<AxiosResponse<any>> {
  return axios.post(`${process.env.BALENA_SUPERVISOR_ADDRESS}/v1/shutdown?apikey=${process.env.BALENA_SUPERVISOR_API_KEY}`)
}

export function restartDevice ():Promise<AxiosResponse<any>> {
  return axios.post(`${process.env.BALENA_SUPERVISOR_ADDRESS}/v1/restart?apikey=${process.env.BALENA_SUPERVISOR_API_KEY}`, { appId: process.env.BALENA_APP_ID})
}