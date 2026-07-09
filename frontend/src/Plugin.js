import React, { useEffect, useRef, useState } from 'react'
import {
  api,
  useAlert,
  Page,
  ListHeader,
  Card,
  SectionHeader,
  StatTile,
  KeyVal,
  StatusDot,
  ModalConfirm,
  Loading,
  Button,
  ButtonText,
  Box,
  Text,
  ScrollView,
  HStack,
  VStack
} from '@spr-networks/plugin-ui'

const PLUGIN_BASE = `/plugins/${api.pluginURI() || 'spr-atlas'}`

const fmtUptime = (secs) => {
  if (!secs || secs < 0) return '—'
  const d = Math.floor(secs / 86400)
  const h = Math.floor((secs % 86400) / 3600)
  const m = Math.floor((secs % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m ${secs % 60}s`
}

const copyText = (text) => {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text)
  }
  return new Promise((resolve, reject) => {
    try {
      const el = document.createElement('textarea')
      el.value = text
      el.style.position = 'fixed'
      el.style.opacity = '0'
      document.body.appendChild(el)
      el.focus()
      el.select()
      document.execCommand('copy')
      document.body.removeChild(el)
      resolve()
    } catch (e) {
      reject(e)
    }
  })
}

export default function Plugin() {
  const alert = useAlert()
  const [status, setStatus] = useState(null)
  const [keyInfo, setKeyInfo] = useState(null)
  const [logs, setLogs] = useState([])
  const [loading, setLoading] = useState(true)
  const [showRestart, setShowRestart] = useState(false)
  const timerRef = useRef(null)

  const refresh = (initial = false) => {
    Promise.allSettled([
      api.get(`${PLUGIN_BASE}/status`),
      api.get(`${PLUGIN_BASE}/key`),
      api.get(`${PLUGIN_BASE}/logs?lines=200`)
    ]).then(([st, key, lg]) => {
      if (st.status === 'fulfilled') setStatus(st.value)
      if (key.status === 'fulfilled') setKeyInfo(key.value)
      if (lg.status === 'fulfilled') setLogs(lg.value?.Lines || [])
      if (initial && st.status === 'rejected') {
        alert.error('Failed to load probe status', st.reason)
      }
      setLoading(false)
    })
  }

  useEffect(() => {
    refresh(true)
    timerRef.current = setInterval(refresh, 10000)
    return () => clearInterval(timerRef.current)
  }, [])

  const doRestart = () => {
    setShowRestart(false)
    api
      .post(`${PLUGIN_BASE}/restart`)
      .then(() => {
        alert.success('Probe restarting')
        setTimeout(refresh, 2000)
      })
      .catch((err) => alert.error('Failed to restart probe', err))
  }

  const doCopyKey = () => {
    if (!keyInfo?.PublicKey) return
    copyText(keyInfo.PublicKey)
      .then(() => alert.success('Public key copied to clipboard'))
      .catch(() => alert.error('Copy failed — select the key text manually'))
  }

  if (loading) {
    return (
      <Page>
        <Loading />
      </Page>
    )
  }

  const running = !!status?.Running
  const connected = !!status?.Connected

  return (
    <Page>
      <ListHeader
        title="RIPE Atlas Probe"
        description="Software probe measuring internet connectivity for the RIPE Atlas network"
      >
        <Button size="sm" variant="outline" onPress={() => refresh()}>
          <ButtonText>Refresh</ButtonText>
        </Button>
      </ListHeader>

      <Card>
        <SectionHeader
          title="Status"
          right={<StatusDot online={running && connected} warn={running && !connected} />}
        />
        <HStack flexWrap="wrap" gap="$2">
          <StatTile label="Probe" value={running ? 'Running' : 'Stopped'} />
          <StatTile
            label="Controller"
            value={connected ? 'Connected' : status?.Registered ? 'Registering' : 'Not connected'}
          />
          <StatTile label="Uptime" value={fmtUptime(status?.UptimeSeconds)} mono />
          <StatTile label="Version" value={status?.Version || '—'} mono />
        </HStack>
        <VStack space="sm" mt="$3">
          {status?.ControllerHost ? (
            <KeyVal label="Assigned controller" value={status.ControllerHost} mono />
          ) : null}
          {status?.LastExit && !running ? (
            <KeyVal label="Last exit" value={status.LastExit} mono />
          ) : null}
          <HStack justifyContent="flex-end">
            <Button
              size="xs"
              variant="outline"
              action="negative"
              onPress={() => setShowRestart(true)}
            >
              <ButtonText>Restart Probe</ButtonText>
            </Button>
          </HStack>
        </VStack>
      </Card>

      <Card>
        <SectionHeader
          title="Registration"
          right={<StatusDot online={connected} warn={!connected && !!keyInfo?.Exists} />}
        />
        {!connected ? (
          <VStack space="sm" mb="$3">
            <Text size="sm" color="$muted500">
              1. Copy the probe public key below.
            </Text>
            <Text size="sm" color="$muted500">
              2. Submit it on the RIPE Atlas software probe application page
              (atlas.ripe.net/apply/swprobe) with your RIPE NCC Access account.
            </Text>
            <Text size="sm" color="$muted500">
              3. Once approved, the probe connects automatically — no restart
              needed. Status above turns green when connected.
            </Text>
          </VStack>
        ) : (
          <Text size="sm" color="$muted500" mb="$3">
            This probe is registered and connected to a RIPE Atlas controller.
          </Text>
        )}
        {keyInfo?.Exists ? (
          <VStack space="md">
            <Box
              p="$3"
              borderRadius="$md"
              borderWidth={1}
              borderColor="$borderColorCardLight"
              bg="$backgroundContentLight"
              sx={{
                _dark: {
                  bg: '$backgroundContentDark',
                  borderColor: '$borderColorCardDark'
                }
              }}
            >
              <Text size="xs" fontFamily="$mono" selectable>
                {keyInfo.PublicKey}
              </Text>
            </Box>
            <KeyVal label="Fingerprint" value={keyInfo.Fingerprint} mono />
            <HStack space="md" flexWrap="wrap">
              <Button size="sm" onPress={doCopyKey}>
                <ButtonText>Copy Public Key</ButtonText>
              </Button>
              <Button
                size="sm"
                variant="outline"
                onPress={() => window.open(keyInfo.RegisterURL || 'https://atlas.ripe.net/apply/swprobe/', '_blank')}
              >
                <ButtonText>Open Registration Page</ButtonText>
              </Button>
            </HStack>
          </VStack>
        ) : (
          <Text size="sm" color="$muted500">
            No probe key yet — it is generated on the plugin's first start.
            Check the logs below if this persists.
          </Text>
        )}
      </Card>

      <Card>
        <SectionHeader title="Probe Log" count={logs.length} />
        {logs.length ? (
          <ScrollView
            maxHeight={320}
            p="$3"
            borderRadius="$md"
            borderWidth={1}
            borderColor="$borderColorCardLight"
            bg="$backgroundContentLight"
            sx={{
              _dark: {
                bg: '$backgroundContentDark',
                borderColor: '$borderColorCardDark'
              }
            }}
          >
            <VStack space="xs">
              {logs.map((line, i) => (
                <Text key={i} size="xs" fontFamily="$mono">
                  {line}
                </Text>
              ))}
            </VStack>
          </ScrollView>
        ) : (
          <Text size="sm" color="$muted500">
            No log output captured yet.
          </Text>
        )}
      </Card>

      <ModalConfirm
        isOpen={showRestart}
        onClose={() => setShowRestart(false)}
        onConfirm={doRestart}
        title="Restart the probe?"
        message="Running measurements are interrupted; the probe reconnects to its controller automatically. The probe key is not affected."
        confirmText="Restart"
        destructive
      />
    </Page>
  )
}
