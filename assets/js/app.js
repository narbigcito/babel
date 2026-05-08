import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

// Auto-scroll al fondo cuando llegan nuevos mensajes
Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    // Solo scroll si ya estaba cerca del fondo
    const el = this.el
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120
    if (nearBottom) this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

// Enter para enviar, Shift+Enter para nueva línea
Hooks.ChatInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        const form = this.el.closest("form")
        if (form) form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
      }
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
