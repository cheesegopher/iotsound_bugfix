import * as cote from 'cote'
import BalenaAudio from 'balena-audio'
import SoundAPI from './SoundAPI'
import SoundConfig from './SoundConfig'
import { constants } from './constants'
import { getSdk } from 'balena-sdk'

// balenaSound core
const config: SoundConfig = new SoundConfig()
const audioBlock: BalenaAudio = new BalenaAudio(`tcp:${config.device.ip}:4317`)
const soundAPI: SoundAPI = new SoundAPI(config, audioBlock)
config.bindAudioBlock(audioBlock)

// init balenaCloud sdk
// Only available on balenaCloud-managed devices, unmanaged devices have no BALENA_API_KEY
const sdk = getSdk({ apiUrl: 'https://api.balena-cloud.com/' })
const hasBalenaCloud: boolean = !!process.env.BALENA_API_KEY
if (hasBalenaCloud) {
  sdk.auth.logout()
  sdk.auth.loginWithToken(process.env.BALENA_API_KEY!)
}

// Fleet communication
let discoveryOptions: any = {
  log: false,
  helloLogsEnabled: false,
  statusLogsEnabled: false
}
const fleetPublisher: cote.Publisher = new cote.Publisher({ name: 'balenaSound publisher' }, discoveryOptions)
const fleetSubscriber: cote.Subscriber = new cote.Subscriber({ name: 'balenaSound subscriber' }, discoveryOptions)

init()
async function init() {
  // On boot the network may not be up yet. Without an IP address the device would advertise
  // 'localhost' as multi-room master, which other containers and devices can't reach
  for (let i = 0; i < 30 && config.device.ip === 'localhost'; i++) {
    if (i === 0) {
      console.log('Waiting for an IP address...')
    }
    await timeout(1000)
    config.refreshIPAddress()
  }
  if (config.device.ip === 'localhost') {
    console.log('No IP address found, using localhost. Multi-room will not work across devices.')
  }

  await soundAPI.listen(constants.port)
  await audioBlock.listen()
  await audioBlock.setVolume(constants.volume)

  // For multi room, allow cote to establish connections before sending fleet-sync
  if (config.isMultiRoomEnabled()) {
    await timeout(constants.coteDelay)
    console.log('Joining the fleet, requesting master info with fleet-sync...')
    fleetPublisher.publish('fleet-sync', { type: 'sync', origin: config.device.ip })
  }

  // Periodically sync the fleet
  setInterval(() => {
    if (config.refreshIPAddress()) {
      console.log(`IP address changed to ${config.device.ip}`)
    }
    if (config.isMultiRoomEnabled()) {
      fleetPublisher.publish('fleet-sync', { type: 'sync', origin: config.device.ip })
    }
  }, constants.multiroom.pollInterval)
}

// Event: "mode-change"
// Source: sound supervisor API
// When switching into a multi-room mode, ask the fleet who the current master is
config.onModeChange((mode, oldMode) => {
  console.log(`Mode changed from ${oldMode} to ${mode}`)
  if (config.isMultiRoomEnabled()) {
    console.log('Requesting master info with fleet-sync...')
    fleetPublisher.publish('fleet-sync', { type: 'sync', origin: config.device.ip })
  }
})

// Event: "play"
// Source: audio block
// On audio playback, set this server as the multiroom-master
// We check the input sink that receives all audio sources
audioBlock.on('play', async (sink: any) => {
  if (constants.debug) {
    console.log(`[event] Audio block: play`)
    console.log(sink)
  }

  if (config.isMultiRoomServer() && sink.name === constants.inputSink) {
    console.log(`Playback started, announcing ${config.device.ip} as multi-room master!`)
    fleetPublisher.publish('fleet-update', { type: 'master', master: config.device.ip })
  }

  // Temporary usage tracking for balenaHub metrics
  if (hasBalenaCloud) {
    try {
      await sdk.models.device.tags.set(process.env.BALENA_DEVICE_UUID!, 'metrics:play', '') // BALENA_DEVICE_UUID is always present in balenaOS
    } catch (error) {
      console.log(error.message)
    }
  }

})

// Event: "fleet-update"
// Source: fleet
// If the master server changed, reset multiroom-client service
fleetSubscriber.on('fleet-update', async (data: any) => {
  if (constants.debug) {
    console.log(`[event] fleet: fleet-update`)
    console.log(data)
  }

  if (config.isNewMultiRoomMaster(data.master) && !config.multiroom.forced && !constants.multiroom.disallowUpdates) {
    console.log(`Multi-room master has changed to ${data.master}, restarting snapcast-client...`)
    config.setMultiRoomMaster(data.master)
  }
})

// Event: "fleet-sync"
// Source: fleet
// When it receives this event the multiroom master announces itself as the master
// This happens when a new device joines the fleet but also periodically
fleetSubscriber.on('fleet-sync', (data: any) => {
  if (constants.debug) {
    console.log(`[event] fleet: fleet-sync`)
    console.log(data)
  }

  if (config.isMultiRoomMaster() && data.origin !== config.device.ip) {
    fleetPublisher.publish('fleet-update', { type: 'master', master: config.multiroom.master })
  }
})

async function timeout (delay: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, delay))
}